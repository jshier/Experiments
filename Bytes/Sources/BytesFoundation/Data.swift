public import Foundation

// Foundation's `Data` with spans: it has `bytes` (a `RawSpan` view), but no way to append one or start from one.
// Apart from `Bytes`, which doesn't depend on Foundation.

public extension Data {
    /// A copy of `bytes`.
    ///
    /// - Parameter bytes: The bytes to copy.
    @inlinable
    init(copying bytes: RawSpan) {
        self.init(capacity: bytes.byteCount)
        append(copying: bytes)
    }

    /// Appends a copy of `bytes`: the `Data` counterpart of `[UInt8]`'s `append(copying:)`.
    ///
    /// ```swift
    /// var result = Data(capacity: expected)
    /// try decoder.decode(entry) { chunk in result.append(copying: chunk) }
    /// ```
    ///
    /// - Parameter bytes: The bytes to append.
    @inlinable
    mutating func append(copying bytes: RawSpan) {
        // Unsafe: a pointer to the span's memory. Safe: `Data` only reads it, within the closure.
        bytes.withUnsafeBytes { unsafe append(contentsOf: $0) }
    }

    /// Appends a copy of `bytes`.
    ///
    /// - Parameter bytes: The bytes to append.
    @available(*, deprecated, renamed: "append(copying:)")
    @inlinable
    mutating func append(_ bytes: RawSpan) {
        append(copying: bytes)
    }
}
