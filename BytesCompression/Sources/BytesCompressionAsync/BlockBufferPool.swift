public import Bytes
public import BytesAsync
public import Synchronization

// The decoding engine's waits (a free buffer, a block job, a decoded block) are BytesAsync's: a free buffer is an
// index from its closable `AsyncIndexPool`, a block job comes through its `AsyncQueue`, and the consumer waits with
// `wait(in:_:)` (`Mutex` state plus the standard library's noncopyable `Continuation`). Memory made once (block buffers, read buffers, decoder scratch) is Bytes' `RawStorage`,
// whose `reuse`/`giveBack` keep only a floor of a large read buffer resident between uses. Every type is inlinable
// with `@usableFromInline` state (BytesAsync's pattern), so its users' calls (one per file, in an extraction) compile
// as they did when this was NativeAEA's `SegmentBufferPool`.

/// How a pool's buffers are divided, chosen within a byte budget (``BlockBufferPool/sizing(blockCapacity:carryCapacity:decoders:extraBuffers:heldBuffers:consumerBuffers:scratchCapacity:staged:budget:)``):
/// the decoders its engine runs, the buffers decoding may run ahead by, the ones the consumer's side may hold beyond
/// decoding (writers'), and the ones the consumer itself holds while it waits for its next block.
public struct BlockPoolSizing: Sendable, Equatable {
    /// Decoder tasks: each holds a buffer while it decodes (and its read buffer, and a staging buffer, if any).
    public var decoders: Int
    /// Decoded blocks held at once beyond one per decoder.
    public var extraBuffers: Int
    /// Buffers the consumer's side holds beyond decoding: a client runs at most this many writers.
    public var heldBuffers: Int
    /// Buffers the consumer holds at once while it waits for its next block: the block it read, and any earlier ones it
    /// keeps until a later one arrives. Never cut: with fewer, a decoder could find no buffer for the block it waits for.
    public var consumerBuffers: Int
    /// The memory these counts take at most, in bytes: the pool's buffers, the decoders' read buffers, and staging.
    public var byteCount: Int
    /// The room before each block the counts were sized with (``BlockBufferPool/carryCapacity``): a pool made from
    /// this sizing has it.
    public var carryCapacity: Int

    /// The pool's buffers: one per decoder, the extra ones, the held ones, and the consumer's.
    public var bufferCount: Int { decoders + extraBuffers + heldBuffers + consumerBuffers }

    @inlinable
    public init(decoders: Int, extraBuffers: Int, heldBuffers: Int, consumerBuffers: Int = 1, byteCount: Int, carryCapacity: Int = 0) {
        self.decoders = decoders
        self.extraBuffers = extraBuffers
        self.heldBuffers = heldBuffers
        self.consumerBuffers = consumerBuffers
        self.byteCount = byteCount
        self.carryCapacity = carryCapacity
    }
}

/// A fixed set of buffers that each hold one decoded block, handed out in the order they're asked for and returned
/// when the last reference to one is released.
///
/// Layout of a buffer: a carry region of ``carryCapacity`` bytes, then the block's bytes, then 64 bytes of slack (for
/// 16-byte copy loops), rounded to 16 KiB. When something a consumer parses (an Apple Archive entry's header) starts at
/// the end of one block, the consumer copies its first bytes into the next buffer's carry region, just before that
/// block's bytes (``carry(_:from:at:to:)``), so it's contiguous. How large a carry can be is the consumer's format's
/// rule (Apple Archive's headers are at most 65,535 bytes), so the client sizes the region; a pool nothing carries in
/// has none.
///
/// Memory: `count * stride`, allocated once. The count bounds how far decoding runs ahead of the consumer: decoders
/// suspend until a buffer is free.
///
/// A buffer is held by ``Buffer`` leases (each one reference, released when the lease is dropped) or, where a holder
/// keeps it in a copyable value (a write job's contents), by its index (``Buffer/detach()``), with ``retain(_:)`` and
/// ``release(_:)``.
public final class BlockBufferPool: Sendable {
    /// One reference to a buffer of the pool: dropped, it releases the reference (the last one returns the buffer to
    /// the pool, or hands it to a task waiting for one).
    ///
    /// ```swift
    /// guard let buffer = await pool.acquire() else { return }   // released however this scope ends
    /// try decode(into: buffer)
    /// slot.buffer = buffer.detach()                              // the slot holds the reference now, by index
    /// ```
    public struct Buffer: ~Copyable, Sendable {
        /// The pool the buffer belongs to (kept alive by the lease).
        public let pool: BlockBufferPool
        /// The buffer's index; −1 once ``detach()`` gave the reference up.
        @usableFromInline var _index: Int

        /// Takes over one reference the caller holds to buffer `index`: the engine's, where a buffer comes out of the
        /// pool (``BlockBufferPool/acquire()``) or out of a published slot to the consumer.
        @inlinable
        init(adopting index: Int, in pool: BlockBufferPool) {
            self.pool = pool
            _index = index
        }

        /// The buffer's index in its pool: for ``BlockBufferPool/bytes(_:at:count:)`` and its other index-taking
        /// methods while the lease is held.
        @inlinable
        public var index: Int { _index }

        /// Another reference to the same buffer.
        @inlinable
        public borrowing func share() -> Buffer {
            pool.retain(_index)
            return Buffer(adopting: _index, in: pool)
        }

        /// Gives the reference up as the buffer's index, for a holder that keeps it in a copyable value and releases it
        /// with ``BlockBufferPool/release(_:)``.
        @inlinable
        public consuming func detach() -> Int {
            let index = _index
            // A sentinel, not `discard self`: the lease holds its pool strongly, and `discard` needs trivially destroyed
            // stored properties.
            _index = -1
            return index
        }

        @inlinable
        deinit {
            if _index >= 0 { pool.release(_index) }
        }
    }

    /// Room before each block for the start of something that continues in it (``carry(_:from:at:to:)``): bytes at
    /// negative offsets, from `-carryCapacity`.
    public let carryCapacity: Int

    /// The buffers (for tests: ``sized(blockCapacity:carryCapacity:decoders:extraBuffers:heldBuffers:consumerBuffers:heldUntilActivated:scratchCapacity:staged:budget:)``'s).
    @usableFromInline package let count: Int
    /// The largest block a buffer holds.
    public let blockCapacity: Int
    /// The buffers the pool was sized for the consumer's side to hold beyond decoding: a client runs at most this many
    /// writers (each may hold a buffer through a job), fewer than it asked for when the budget cut them.
    public let heldBuffers: Int
    /// Bytes from one buffer's start to the next's.
    @usableFromInline let stride: Int
    @usableFromInline let storage: RawStorage
    /// References per buffer: the consumer's while it reads the block, plus one per job using its bytes. One
    /// allocation for all of them.
    @usableFromInline let references: RelaxedCounters
    /// Which buffers are free: handed out last released first, to the longest waiting task when none is, closable, and
    /// with buffers `active..<count` held back until ``activateAll()`` (BytesAsync's index pool).
    @usableFromInline let handout: AsyncIndexPool
    /// Buffers in use at once, at most.
    public let peakInUse = Atomic<Int>(0)
    @usableFromInline let inUse = Atomic<Int>(0)

    /// - Parameters:
    ///   - count: The buffers.
    ///   - blockCapacity: The largest block each holds.
    ///   - active: Buffers handed out until ``activateAll()`` (all of them if `nil`): for a pool sized before its
    ///     consumer is known (an AEA payload, until its first segment says whether writers will hold its buffers). The
    ///     others are never touched until then, so their pages never become resident if they're never activated.
    ///   - heldBuffers: What the consumer's side may hold beyond decoding (``heldBuffers``).
    ///   - carryCapacity: The room before each block for what a consumer carries into it (``carryCapacity``): the most
    ///     its format can carry (an Apple Archive header's 65,535 bytes), or 0 if it carries nothing.
    @inlinable
    public init(count: Int, blockCapacity: Int, active: Int? = nil, heldBuffers: Int = 0, carryCapacity: Int = 0) {
        precondition(carryCapacity >= 0, "a negative carry region")
        self.count = count
        self.blockCapacity = blockCapacity
        self.heldBuffers = heldBuffers
        self.carryCapacity = carryCapacity
        stride = Self.stride(blockCapacity: blockCapacity, carryCapacity: carryCapacity)
        storage = RawStorage(byteCount: stride * count)
        references = RelaxedCounters(count: count)
        // Everyone who can wait for a buffer holds none of the others: at most `count` waiters.
        handout = AsyncIndexPool(count: count, active: max(1, min(count, active ?? count)), waiters: count)
    }

    /// Bytes from one buffer's start to the next's, for blocks of up to `blockCapacity` bytes: the carry region, the
    /// block, room past it for decoders that copy in 16-byte steps, rounded up to 16 KiB (a multiple of the page size).
    @inlinable
    public static func stride(blockCapacity: Int, carryCapacity: Int = 0) -> Int {
        (carryCapacity + blockCapacity + 64 + 16_383) & ~16_383
    }

    /// The bytes of the buffers handed out now (all of them once ``activateAll()`` has run).
    @inlinable
    public var activeByteCount: Int { handout.activeCount * stride }

    /// How an engine's decoders and its consumer divide a pool, within `budget` bytes: the one place a pool's size is
    /// decided (``sized(blockCapacity:carryCapacity:decoders:extraBuffers:heldBuffers:consumerBuffers:heldUntilActivated:scratchCapacity:staged:budget:)``
    /// makes every ``ParallelBlockDecoder`` pool from it).
    ///
    /// The pool holds a buffer per decoder (it takes one before it takes a block), `extraBuffers` (how far decoding may
    /// run ahead of the consumer), `heldBuffers` (what the consumer's side holds beyond decoding: writers' references),
    /// and `consumerBuffers`, what the consumer holds while it waits for its next block (the block it read, and any
    /// earlier ones it keeps until a later one arrives), so a decoder can always take the block it waits for (fewer could
    /// wait forever). Each decoder may also have a read buffer (`scratchCapacity`), and a stream copied from an upstream
    /// source has staging: a buffer per decoder and two more (the producer's, and one more).
    ///
    /// When all of that is over `budget` (large blocks: `pbz` allows 256 MiB, so do AEA segments), the counts come down
    /// in this order (review 2026-11-23 §1.6, fix plan B1):
    /// 1. **Held buffers**, to as many as fit beside the least that can run (one decoder, no extra buffers): how far
    ///    writers may lag. At least one stays if any were asked for (a client's one writer).
    /// 2. **Extra buffers**, to as many as fit beside every decoder: they only let decoding run ahead of the consumer.
    /// 3. **Decoders**, to as many as fit with no extra buffers: each costs a buffer, its read buffer, and its staging.
    ///
    /// The counts never go below one decoder, the held buffers (at least one if any were asked for), the consumer's, and
    /// staging's: what liveness needs, even over the budget (two 256 MiB buffers and a 256 MiB read buffer, for a
    /// listing).
    ///
    /// - Parameters:
    ///   - blockCapacity: The largest block each buffer holds.
    ///   - carryCapacity: The room before each block for what the consumer carries into it (``carryCapacity``).
    ///   - decoders: Decoder tasks (at least one is counted).
    ///   - consumerBuffers: What the consumer holds while it waits for its next block (at least one is counted).
    ///   - scratchCapacity: Each decoder's read buffer, if it has one.
    ///   - staged: Whether the engine copies blocks into staging (a stream in an upstream source's blocks): staging
    ///     buffers of `blockCapacity` too (with no carry region: only the engine reads them).
    ///   - budget: Bytes for all of it, or `nil` for no limit.
    @inlinable
    public static func sizing(
        blockCapacity: Int, carryCapacity: Int = 0, decoders: Int, extraBuffers: Int, heldBuffers: Int = 0, consumerBuffers: Int = 1,
        scratchCapacity: Int? = nil, staged: Bool = false, budget: Int? = nil
    ) -> BlockPoolSizing {
        let stride = Self.stride(blockCapacity: blockCapacity, carryCapacity: carryCapacity)
        let staging = staged ? Self.stride(blockCapacity: blockCapacity) : 0
        let consumer = max(1, consumerBuffers)
        // A decoder's buffer, read buffer, and staging buffer; the consumer's, and staging's two.
        let perDecoder = stride + max(0, scratchCapacity ?? 0) + staging
        let fixed = consumer * stride + 2 * staging
        func bytes(_ decoders: Int, _ extra: Int, _ held: Int) -> Int { decoders * perDecoder + (extra + held) * stride + fixed }
        var decoders = max(1, decoders), extra = max(0, extraBuffers), held = max(0, heldBuffers)
        if let budget, bytes(decoders, extra, held) > budget {
            // 1. Held buffers beside the least that runs; one stays (a client's one writer).
            let room = max(0, budget - bytes(1, 0, 0)) / stride
            held = max(min(held, 1), min(held, room))
            // 2. Extra buffers beside every decoder; 3. if none fit, decoders.
            let withoutExtras = bytes(decoders, 0, held)
            if withoutExtras <= budget {
                extra = min(extra, (budget - withoutExtras) / stride)
            } else {
                extra = 0
                decoders = max(1, min(decoders, 1 + max(0, budget - bytes(1, 0, held)) / perDecoder))
            }
        }
        return BlockPoolSizing(
            decoders: decoders, extraBuffers: extra, heldBuffers: held, consumerBuffers: consumer, byteCount: bytes(decoders, extra, held),
            carryCapacity: carryCapacity
        )
    }

    /// A pool divided as ``sizing(blockCapacity:carryCapacity:decoders:extraBuffers:heldBuffers:consumerBuffers:scratchCapacity:staged:budget:)``
    /// divides it, with its carry region.
    ///
    /// - Parameter heldUntilActivated: For a pool sized before its consumer is known (an AEA payload, until its first
    ///   segment says whether writers will hold its buffers): what the consumer holds, beyond one buffer, until
    ///   ``activateAll()``, which stands for the held buffers and the consumer's others until then. `nil`: every buffer
    ///   is handed out from the start.
    @inlinable
    public convenience init(sizing: BlockPoolSizing, blockCapacity: Int, heldUntilActivated: Int? = nil) {
        let base = sizing.decoders + sizing.extraBuffers + 1
        self.init(
            count: sizing.bufferCount, blockCapacity: blockCapacity, active: heldUntilActivated.map { base + max(0, $0) },
            heldBuffers: sizing.heldBuffers, carryCapacity: sizing.carryCapacity
        )
    }

    /// A pool for an engine's decoders and its consumer, divided by
    /// ``sizing(blockCapacity:carryCapacity:decoders:extraBuffers:heldBuffers:consumerBuffers:scratchCapacity:staged:budget:)``
    /// (the decoders it counts are the ones to run: ``ParallelBlockDecoder`` takes them from the same sizing).
    @inlinable
    public static func sized(
        blockCapacity: Int, carryCapacity: Int = 0, decoders: Int, extraBuffers: Int, heldBuffers: Int = 0, consumerBuffers: Int = 1,
        heldUntilActivated: Int? = nil, scratchCapacity: Int? = nil, staged: Bool = false, budget: Int? = nil
    ) -> BlockBufferPool {
        BlockBufferPool(
            sizing: sizing(
                blockCapacity: blockCapacity, carryCapacity: carryCapacity, decoders: decoders, extraBuffers: extraBuffers,
                heldBuffers: heldBuffers, consumerBuffers: consumerBuffers, scratchCapacity: scratchCapacity, staged: staged, budget: budget
            ),
            blockCapacity: blockCapacity, heldUntilActivated: heldUntilActivated
        )
    }

    /// Hands out every buffer from now on: the inactive ones go to tasks waiting for a buffer, then to the bottom of the
    /// free list (recently freed buffers, whose pages are resident, stay first).
    @inlinable
    public func activateAll() {
        handout.activateAll()
    }

    /// Buffers acquired and not yet released.
    @inlinable
    public var buffersInUse: Int { inUse.load(ordering: .relaxed) }

    /// Tasks waiting in ``acquire()`` (for tests).
    @inlinable
    package var waiting: Int { handout.waiting }

    /// A free buffer now, with one reference: `nil` if there's none, or the pool is closed.
    @inlinable
    package func tryAcquire() -> Buffer? {
        guard let index = handout.tryAcquire() else { return nil }
        return taken(index)
    }

    /// Takes a free buffer with one reference, suspending the task until one is released if none is free.
    ///
    /// - Returns: `nil` once the pool is closed.
    @inlinable
    package nonisolated(nonsending) func acquire() async -> Buffer? {
        guard let index = await handout.acquire() else { return nil }
        return taken(index)
    }

    @inlinable
    func taken(_ index: Int) -> Buffer {
        references.store(1, at: index)
        let now = inUse.add(1, ordering: .relaxed).newValue
        peakInUse.max(now, ordering: .relaxed)
        return Buffer(adopting: index, in: self)
    }

    /// Adds a reference to buffer `index`: one per job that points into it.
    @inlinable
    public func retain(_ index: Int) {
        references.add(at: index)
    }

    /// Drops a reference; the last one hands the buffer to the task waiting longest for one, or returns it to the pool.
    @inlinable
    public func release(_ index: Int) {
        // The last release publishes every holder's reads of the buffer to its next user: not relaxed.
        if references.withAtomic(at: index, { $0.subtract(1, ordering: .acquiringAndReleasing).newValue }) == 0 {
            inUse.subtract(1, ordering: .relaxed)
            handout.release(index)
        }
    }

    /// Stops handing out buffers: tasks waiting in ``acquire()`` get `nil`, and so do later calls. Buffers still go back
    /// to the pool when released.
    @inlinable
    func close() {
        handout.close()
    }

    /// Where `index`'s block bytes start (after the carry region): for decoders, which write disjoint regions of the
    /// storage from several tasks (a span can't be split between them).
    ///
    /// Unsafe: the pool's memory, valid while the pool lives; whoever holds a reference to the buffer may write it.
    @unsafe @inlinable @inline(__always)
    func blockBase(_ index: Int) -> UnsafeMutableRawPointer {
        unsafe storage.pointer(index * stride + carryCapacity)
    }

    /// Bytes `offset..<offset + byteCount` of buffer `index`, counted from its block base (the carry region is at
    /// negative offsets, from `-carryCapacity`). The caller holds a reference to the buffer while it reads them.
    @inlinable @inline(__always) @_lifetime(borrow self)
    public func bytes(_ index: Int, at offset: Int, count byteCount: Int) -> RawSpan {
        checkRange(index, offset, byteCount)
        // Unsafe (the next two): a span over the pool's storage, its lifetime set by hand to a borrow of the pool.
        // Safe: within buffer `index` (checked above), in storage the pool owns and frees only when it goes, which the
        // borrow outlasts.
        let span = unsafe RawSpan(_unsafeStart: blockBase(index) + offset, byteCount: byteCount)
        return unsafe _overrideLifetime(span, borrowing: self)
    }

    /// Calls `body` with bytes `offset..<offset + byteCount` of buffer `index` to write, counted as ``bytes(_:at:count:)``
    /// counts. The caller holds a reference to the buffer, and no one else reads or writes those bytes meanwhile.
    @inlinable @inline(__always)
    public func withMutableBytes<R, E: Error>(
        _ index: Int, at offset: Int, count byteCount: Int, _ body: (inout MutableRawSpan) throws(E) -> R
    ) throws(E) -> R {
        checkRange(index, offset, byteCount)
        // Unsafe: a mutable span over the pool's storage. Safe: within buffer `index` (checked above), in storage the
        // pool owns; the span ends with `body`.
        var span = unsafe MutableRawSpan(_unsafeStart: blockBase(index) + offset, byteCount: byteCount)
        return try body(&span)
    }

    /// Copies `byteCount` bytes from `offset` in buffer `source` to just before buffer `target`'s block bytes, into its
    /// carry region: the start of a header that continues in `target`. The caller holds both buffers.
    ///
    /// - Precondition: `byteCount` is at most ``carryCapacity``.
    @inlinable
    public func carry(_ byteCount: Int, from source: Int, at offset: Int, to target: Int) {
        precondition(byteCount <= carryCapacity, "a carry larger than the carry region")
        let from = bytes(source, at: offset, count: byteCount)
        withMutableBytes(target, at: -byteCount, count: byteCount) { $0.copyBytes(from: from, toByteOffset: 0) }
    }

    /// Checks that `offset..<offset + byteCount` is within a buffer: from `-carryCapacity` to the end of its stride.
    @inlinable @inline(__always)
    func checkRange(_ index: Int, _ offset: Int, _ byteCount: Int) {
        precondition(
            UInt(bitPattern: index) < UInt(bitPattern: count) && offset >= -carryCapacity && byteCount >= 0
                && byteCount <= stride - carryCapacity - offset,
            "bytes outside a block buffer"
        )
    }
}
