// `for`-`in` over `BytesReader`, through the standard library's `Iterable` (macOS 27 and aligned releases).
//
// `Iterable` iterators hand out a whole `Span` of elements per step, not one element per `next()` call, so a
// `for`-`in` loop compiles to an outer loop over spans and an inner loop over contiguous memory that the
// compiler vectorizes. Iterating never moves the cursor: it reads from the cursor's position onward.

// MARK: - BytesReader

extension BytesReader: Iterable {
    public typealias Element = UInt8
    public typealias BorrowingIterator = Span<UInt8>.BorrowingIterator

    /// Iterates the whole unread bytes, without consuming them, as one span of the underlying memory.
    ///
    /// ```swift
    /// var reader = BytesReader(data.span)
    /// for byte in reader { checksum &+= UInt32(byte) }
    /// ```
    ///
    /// Declare the reader with `var` (or take it `borrowing`): in Swift 6.4, a loop over a `let` reader
    /// heap-allocates the cursor once, because the compiler boxes a `~Copyable` `let` that an iterator
    /// borrows.
    @inlinable
    @_lifetime(borrow self)
    public func makeBorrowingIterator() -> Span<UInt8>.BorrowingIterator {
        Span<UInt8>.BorrowingIterator(Span(viewing: remainingBytes))
    }

    @inlinable
    public var underestimatedCount: Int { remainingByteCount }
}

// MARK: - Typed views

public extension BytesReader {
    /// The remaining whole `T` groups, as integers in `byteOrder`, for `for`-`in` loops.
    ///
    /// ```swift
    /// let lengths = reader.values(of: Byte3.self, .bigEndian) // UInt32s
    /// for length in lengths { total &+= length }
    /// ```
    ///
    /// Bind the view to a constant first: Swift 6.4 rejects `for`-`in` directly over a temporary
    /// `~Escapable` value ("lifetime-dependent variable escapes its scope"), including the standard
    /// library's own (`for x in array.span`).
    ///
    /// The cursor doesn't move. Trailing bytes too few for a whole `T` are skipped.
    @inlinable
    @_lifetime(copy self)
    func values<T: ByteGroup>(of _: T.Type, _ byteOrder: ByteOrder) -> ByteGroupValues<T> {
        ByteGroupValues(span: span, byteOffset: _byteOffset, bitOffset: _bitOffset, bitOrder: bitOrder, byteOrder: byteOrder)
    }

    /// The remaining whole `Bits<width>` values, in ``bitOrder``, for `for`-`in` loops.
    ///
    /// ```swift
    /// let nibbles = reader.values(of: Nibble.self)
    /// for nibble in nibbles { histogram[Int(nibble)] += 1 }
    /// ```
    ///
    /// As with ``values(of:_:)``, bind the view to a constant before looping over it. The cursor doesn't
    /// move. Trailing bits too few for a whole value are skipped.
    @inlinable
    @_lifetime(copy self)
    func values<let width: Int>(of _: Bits<width>.Type) -> BitsValues<width> {
        BitsValues(span: span, byteOffset: _byteOffset, bitOffset: _bitOffset, bitOrder: bitOrder)
    }

    /// A cursor at the given position, for iterators.
    @inlinable
    @_lifetime(copy span)
    internal init(_ span: RawSpan, byteOffset: Int, bitOffset: Int, bitOrder: BitOrder) {
        self.init(span, bitOrder: bitOrder)
        _byteOffset = byteOffset
        _bitOffset = bitOffset
    }
}

/// The whole `T` groups from a position in a span, as integers in a byte order. See ``BytesReader/values(of:_:)``.
public struct ByteGroupValues<T: ByteGroup>: Iterable, ~Escapable {
    public typealias Element = T.Integer

    @usableFromInline let span: RawSpan
    @usableFromInline let byteOffset: Int
    @usableFromInline let bitOffset: Int
    @usableFromInline let bitOrder: BitOrder
    @usableFromInline let byteOrder: ByteOrder

    @inlinable
    @_lifetime(copy span)
    init(span: RawSpan, byteOffset: Int, bitOffset: Int, bitOrder: BitOrder, byteOrder: ByteOrder) {
        self.span = span
        self.byteOffset = byteOffset
        self.bitOffset = bitOffset
        self.bitOrder = bitOrder
        self.byteOrder = byteOrder
    }

    @inlinable
    @_lifetime(borrow self)
    public func makeBorrowingIterator() -> Iterator {
        Iterator(cursor: BytesReader(span, byteOffset: byteOffset, bitOffset: bitOffset, bitOrder: bitOrder), byteOrder: byteOrder)
    }

    @inlinable
    public var underestimatedCount: Int {
        BytesReader(span, byteOffset: byteOffset, bitOffset: bitOffset, bitOrder: bitOrder).remainingByteCount / T.byteCount
    }

    /// Decodes up to 1,024 values at a time into its own buffer, and hands out a span of them.
    public struct Iterator: BorrowingIteratorProtocol, ~Copyable, ~Escapable {
        public typealias Element = T.Integer

        @usableFromInline var cursor: BytesReader
        @usableFromInline let byteOrder: ByteOrder
        /// 1,024 values per span (2–16 KB): enough that per-span overhead is amortized, small enough to
        /// stay in L1 between being decoded and being read by the loop body.
        @usableFromInline var buffer = InlineArray<1024, T.Integer>(repeating: 0)
        @inlinable static var capacity: Int { 1024 }

        @inlinable
        @_lifetime(copy cursor)
        init(cursor: consuming BytesReader, byteOrder: ByteOrder) {
            self.cursor = cursor
            self.byteOrder = byteOrder
        }

        @inlinable
        @_lifetime(&self)
        @_lifetime(self: copy self)
        public mutating func nextSpan(maxCount: Int) -> Span<T.Integer> {
            var output = buffer.mutableSpan
            var count = 0
            let byteOrder = byteOrder
            // Unsafe: unchecked stores. Safe: `_forEach` calls this at most `limit` times, which is at most
            // the buffer's capacity. Checked, the store is the only check left in `_forEach`'s loop, and it
            // stops the loop from vectorizing.
            cursor._forEach(T.self, limit: Swift.min(maxCount, Self.capacity)) { group in
                unsafe output[unchecked: count] = group.integer(byteOrder)
                count &+= 1
            }
            return buffer.span.extracting(first: count)
        }
    }
}

/// The whole `Bits<width>` values from a position in a span. See ``BytesReader/values(of:)``.
public struct BitsValues<let width: Int>: Iterable, ~Escapable {
    public typealias Element = Bits<width>

    @usableFromInline let span: RawSpan
    @usableFromInline let byteOffset: Int
    @usableFromInline let bitOffset: Int
    @usableFromInline let bitOrder: BitOrder

    @inlinable
    @_lifetime(copy span)
    init(span: RawSpan, byteOffset: Int, bitOffset: Int, bitOrder: BitOrder) {
        self.span = span
        self.byteOffset = byteOffset
        self.bitOffset = bitOffset
        self.bitOrder = bitOrder
    }

    @inlinable
    @_lifetime(borrow self)
    public func makeBorrowingIterator() -> Iterator {
        Iterator(cursor: BytesReader(span, byteOffset: byteOffset, bitOffset: bitOffset, bitOrder: bitOrder))
    }

    @inlinable
    public var underestimatedCount: Int {
        BytesReader(span, byteOffset: byteOffset, bitOffset: bitOffset, bitOrder: bitOrder).remainingBitCount / width
    }

    /// Decodes up to 4,096 values at a time into its own buffer, and hands out a span of them.
    public struct Iterator: BorrowingIteratorProtocol, ~Copyable, ~Escapable {
        public typealias Element = Bits<width>

        @usableFromInline var cursor: BytesReader
        /// 4,096 values per span (4 KB, from 512–4,096 bytes of input): a narrow width needs many values
        /// per span to amortize the per-span overhead.
        @usableFromInline var buffer = InlineArray<4096, Bits<width>>(repeating: .zero)
        @inlinable static var capacity: Int { 4096 }

        @inlinable
        @_lifetime(copy cursor)
        init(cursor: consuming BytesReader) {
            self.cursor = cursor
        }

        @inlinable
        @_lifetime(&self)
        @_lifetime(self: copy self)
        public mutating func nextSpan(maxCount: Int) -> Span<Bits<width>> {
            var output = buffer.mutableSpan
            var count = 0
            // 4,096 is a multiple of 8, so a view that starts byte-aligned ends each span on a byte boundary,
            // and the next span starts vectorized. Unchecked stores, for the reason above.
            cursor._forEach(Bits<width>.self, limit: Swift.min(maxCount, Self.capacity)) { value in
                unsafe output[unchecked: count] = value
                count &+= 1
            }
            return buffer.span.extracting(first: count)
        }
    }
}
