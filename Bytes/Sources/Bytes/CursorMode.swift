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
/// sub-byte fields in the stream (bit fields within a byte read as a ``Byte`` still work: `flags[Crumb.self,
/// at: 6]`).
public enum ByteAligned: BytesCursorMode {
    @inlinable @inline(__always)
    public static var addressesBits: Bool { false }
}
