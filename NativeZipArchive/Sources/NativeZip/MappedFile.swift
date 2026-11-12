import Foundation
import System

/// A read-only memory mapping of a file, unmapped on deinit.
///
/// Unlike `Data(contentsOf:options: .alwaysMapped)`, the bytes have a stable address for the life of
/// the object, so decoding can span `await`s (see ``ZipDecoder``'s pipelined path) without copying.
///
/// Unsafe throughout: `mmap`/`munmap` return and take raw pointers, and there's no safe owning type for a
/// mapping. Contained here: the pointer is private, the mapping is read-only and immutable, and it's handed
/// out only as a `RawSpan` bound to `self`'s lifetime, or (for the pipelined path) a range-checked buffer
/// that callers must not use after `self` is gone.
@usableFromInline
@safe
final class MappedFile: Sendable {
    // Immutable, read-only memory that lives exactly as long as `self`, so sharing it is safe.
    private nonisolated(unsafe) let base: UnsafeRawPointer?
    @usableFromInline let count: Int

    init(path: FilePath) throws {
        let descriptor = try FileDescriptor.open(path, .readOnly, options: [.closeOnExec])
        defer { try? descriptor.close() }
        let size = try Int(descriptor.stat().size)
        guard size > 0 else {
            unsafe base = nil
            count = 0
            return
        }
        let mapping = unsafe mmap(nil, size, PROT_READ, MAP_PRIVATE, descriptor.rawValue, 0)
        guard unsafe mapping != MAP_FAILED, let mapping = unsafe mapping else { throw Errno(rawValue: errno) }
        unsafe base = UnsafeRawPointer(mapping)
        count = size
    }

    deinit {
        if let base = unsafe base { unsafe munmap(UnsafeMutableRawPointer(mutating: base), count) }
    }

    /// The whole file. The span borrows `self`, which keeps the mapping alive.
    @usableFromInline
    var bytes: RawSpan {
        @_lifetime(borrow self)
        get {
            guard let base = unsafe base else { return RawSpan() }
            let span = unsafe RawSpan(_unsafeStart: base, byteCount: count)
            return unsafe _overrideLifetime(span, borrowing: self)
        }
    }

    /// A pointer to `range` that remains valid as long as `self` is alive. Used only where a decode loop
    /// must outlive a single `withUnsafeBytes` scope (across suspension points).
    ///
    /// - Parameter range: The byte range within the file.
    /// - Returns: A buffer over `range`; empty (with a `nil` base) for an empty file.
    /// - Precondition: `range` lies within `0...count`.
    func stableBuffer(_ range: Range<Int>) -> UnsafeRawBufferPointer {
        precondition(range.lowerBound >= 0 && range.upperBound <= count)
        guard let base = unsafe base else { return unsafe UnsafeRawBufferPointer(start: nil, count: 0) }
        return unsafe UnsafeRawBufferPointer(start: base + range.lowerBound, count: range.count)
    }
}
