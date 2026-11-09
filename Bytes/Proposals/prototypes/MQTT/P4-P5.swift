public import Bytes

// PROTOTYPES of APIs proposed for Bytes (scratch copy only).

extension BytesReader {
    /// P5: a position this cursor was at, to come back to: for parsers that read ahead and then undo it,
    /// where `atomically` can't help (a closure can't return a lifetime-dependent value such as a frame).
    @usableFromInline
    struct Mark {
        @usableFromInline let byteOffset: Int
        @inlinable init(byteOffset: Int) { self.byteOffset = byteOffset }
    }

    /// P5: where the cursor is now.
    @inlinable @inline(__always)
    var mark: Mark { Mark(byteOffset: byteOffset) }

    /// P5: moves back to `mark`, which this cursor was at before. Can't fail, so no `try!`; inside Bytes it
    /// needs no bounds check (a mark is never past the end), only a precondition that it isn't ahead.
    @inlinable @inline(__always)
    @_lifetime(self: copy self)
    mutating func rewind(to mark: Mark) {
        try! seek(toByteOffset: mark.byteOffset)
    }
}

extension RawSpan {
    /// P4: whether the span starts with `prefix`'s bytes: one load and compare, `false` if it's shorter.
    @inlinable @inline(__always)
    func hasPrefix<T: ByteGroup>(_ prefix: T) -> Bool {
        (try? BytesReader(self).peek(T.self)) == prefix
    }
}
