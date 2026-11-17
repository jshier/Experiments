/// A checksum computed incrementally over bytes, whose pieces can be checksummed separately and combined:
/// ``CRC32`` and ``Adler32``.
///
/// ```swift
/// func verify<C: RunningChecksum>(_ chunks: [[UInt8]], as _: C.Type, expecting expected: C.Value) -> Bool {
///     var checksum = C()
///     for chunk in chunks { checksum.update(chunk.span.bytes) }
///     return checksum.value == expected
/// }
/// ```
///
/// For code generic over the checksum a format uses; concrete calls (`CRC32.checksum(bytes)`) compile to the
/// same thing.
public protocol RunningChecksum: Hashable, Sendable {
    /// The checksum's integer type.
    associatedtype Value: FixedWidthInteger & Sendable

    /// The checksum of no bytes: 0 for CRC-32, 1 for Adler-32.
    static var initialValue: Value { get }

    /// The checksum of everything added so far.
    var value: Value { get }

    /// Creates a checksum continuing from `value`, the checksum of earlier bytes (``initialValue`` for none).
    ///
    /// - Parameter value: The checksum of the earlier bytes.
    init(continuing value: Value)

    /// Adds `bytes` to the checksum.
    ///
    /// - Parameter bytes: The bytes to add.
    mutating func update(_ bytes: RawSpan)

    /// The checksum of `bytes` following bytes whose checksum is `value`.
    ///
    /// - Parameters:
    ///   - bytes: The bytes to add.
    ///   - value: The checksum of the earlier bytes.
    /// - Returns: The checksum of both.
    static func checksum(_ bytes: RawSpan, continuing value: Value) -> Value

    /// The checksum of two pieces end to end, from each piece's checksum and the second's length: for pieces
    /// checksummed in parallel.
    ///
    /// - Parameters:
    ///   - first: The first piece's checksum.
    ///   - second: The second piece's checksum, started from ``initialValue``.
    ///   - length: The second piece's length in bytes.
    /// - Returns: The checksum of the first piece followed by the second.
    static func combine(_ first: Value, _ second: Value, secondLength length: Int) -> Value
}

public extension RunningChecksum {
    /// A checksum of no bytes yet: ``initialValue``.
    @inlinable
    init() {
        self.init(continuing: Self.initialValue)
    }

    /// The checksum of `bytes`, from ``initialValue``.
    ///
    /// - Parameter bytes: The bytes.
    /// - Returns: Their checksum.
    @inlinable
    static func checksum(_ bytes: RawSpan) -> Value {
        checksum(bytes, continuing: initialValue)
    }
}

extension CRC32: RunningChecksum {
    /// The CRC-32 of no bytes: 0.
    @inlinable
    public static var initialValue: UInt32 { 0 }
}

extension Adler32: RunningChecksum {
    /// The Adler-32 of no bytes: 1.
    @inlinable
    public static var initialValue: UInt32 { 1 }
}
