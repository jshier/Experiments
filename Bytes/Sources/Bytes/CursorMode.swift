/// How a cursor addresses its data: by bit (``BitAddressable``: ``BytesReader``, ``BytesWriter``) or only by
/// whole bytes (``ByteAligned``: ``AlignedBytesReader``, ``AlignedBytesWriter``).
///
/// One implementation serves both: the byte-level API is written once, generic over the mode, and each
/// cursor is specialized for its mode where it's used. A byte-aligned cursor's bit offset is the constant 0,
/// so its byte operations carry no alignment tests, no partial-byte bookkeeping, and no partial-byte term in
/// ``GenericBytesReader/remainingByteCount``: a loop of byte-level reads or writes compiles to less.
///
/// Byte-aligned clients measured (instructions): MQTT's packet encoding −6% (writer), parsing −1 to −3%
/// (reader), Base64 −2 to −8% on short inputs. See `Benchmarks/RESULTS.md`.
public protocol BytesCursorMode {
    /// Whether cursors in this mode read and write sub-byte fields.
    static var addressesBits: Bool { get }
}

/// Bit and byte fields in any mix: the mode of ``BytesReader`` and ``BytesWriter``.
public enum BitAddressable: BytesCursorMode {
    @inlinable @inline(__always)
    public static var addressesBits: Bool { true }
}

/// Whole bytes only: the mode of ``AlignedBytesReader`` and ``AlignedBytesWriter``, for formats with no
/// sub-byte fields in the stream (bit fields within a byte, read as a ``Byte``, still work by name:
/// `flags[ConnectFlags.willQoS]`, see ``BitField``). With an explicit byte order at each integer; for one
/// order throughout, use the byte-ordered modes below.
public enum ByteAligned: ByteAlignedCursorMode {
    @inlinable @inline(__always)
    public static var addressesBits: Bool { false }
}

/// A mode of whole bytes only: ``ByteAligned``, and the byte-ordered modes ``BigEndianBytes`` and
/// ``LittleEndianBytes``, whose cursors have every byte-aligned operation.
public protocol ByteAlignedCursorMode: BytesCursorMode {}

public extension ByteAlignedCursorMode {
    @inlinable @inline(__always)
    static var addressesBits: Bool { false }
}

/// Whole bytes with a byte order for integers: cursors in these modes read and write integers by type,
/// without a byte order at each call.
///
/// ```swift
/// var reader = BigEndianBytesReader(packet)
/// let length = try reader.read(UInt16.self)
/// let identifier = try reader.read(Int.self, as: Byte3.self)
/// ```
///
/// Everything else is as for ``ByteAligned``: an ordered cursor compiles to the same code as an aligned one
/// passing the order at each read.
public protocol ByteOrderedCursorMode: ByteAlignedCursorMode {
    /// The byte order of integers read and written without one.
    static var byteOrder: ByteOrder { get }
}

/// Whole bytes, integers big-endian (network order): the mode of ``BigEndianBytesReader`` and
/// ``BigEndianBytesWriter``.
public enum BigEndianBytes: ByteOrderedCursorMode {
    @inlinable @inline(__always)
    public static var byteOrder: ByteOrder { .bigEndian }
}

/// Whole bytes, integers little-endian: the mode of ``LittleEndianBytesReader`` and ``LittleEndianBytesWriter``.
public enum LittleEndianBytes: ByteOrderedCursorMode {
    @inlinable @inline(__always)
    public static var byteOrder: ByteOrder { .littleEndian }
}

/// A byte-aligned reader whose integers are big-endian: `try reader.read(UInt32.self)`.
public typealias BigEndianBytesReader = GenericBytesReader<BigEndianBytes>
/// A byte-aligned reader whose integers are little-endian: `try reader.read(UInt32.self)`.
public typealias LittleEndianBytesReader = GenericBytesReader<LittleEndianBytes>
/// A byte-aligned writer whose integers are big-endian: `try writer.write(length)`.
public typealias BigEndianBytesWriter = GenericBytesWriter<BigEndianBytes>
/// A byte-aligned writer whose integers are little-endian: `try writer.write(length)`.
public typealias LittleEndianBytesWriter = GenericBytesWriter<LittleEndianBytes>
