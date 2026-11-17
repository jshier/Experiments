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
        append(bytes)
    }

    /// Appends a copy of `bytes`.
    ///
    /// ```swift
    /// var result = Data(capacity: expected)
    /// try decoder.decode(entry) { chunk in result.append(chunk) }
    /// ```
    ///
    /// - Parameter bytes: The bytes to append.
    @inlinable
    mutating func append(_ bytes: RawSpan) {
        // Unsafe: a pointer to the span's memory. Safe: `Data` only reads it, within the closure.
        bytes.withUnsafeBytes { unsafe append(contentsOf: $0) }
    }
}
