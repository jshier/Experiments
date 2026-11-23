/// Why an HPACK field block couldn't be decoded or encoded (RFC 7541). Payload-free, so throwing allocates nothing.
///
/// Every case but ``headerListTooLarge``, ``malformedField``, ``unfinishedBlock``, and ``outputTooSmall`` is a
/// connection error of type COMPRESSION_ERROR (RFC 9113 §4.3): the decoder's table can no longer be trusted.
/// ``headerListTooLarge`` is thrown after the representation's effect on the table is applied, so the rest of the block
/// can still be decoded to keep the table in step (RFC 9113 §10.5.1) and the stream refused (431, or RST_STREAM).
@frozen
public enum HPACKError: Error, Sendable, Hashable {
    /// The block ends inside a representation (a truncated integer or string).
    case truncated
    /// An index of 0, or past the static and dynamic tables (RFC 7541 §2.3.3).
    case invalidIndex
    /// An integer past 2³² − 1, or with more than 5 continuation bytes (RFC 7541 §5.1).
    case integerOverflow
    /// A Huffman-coded string with EOS in it, or padding longer than 7 bits or not all ones (RFC 7541 §5.2).
    case invalidHuffmanCode
    /// A dynamic table size update above the SETTINGS_HEADER_TABLE_SIZE the decoder advertised (RFC 7541 §6.3).
    case tableSizeUpdateTooLarge
    /// A dynamic table size update after a field in the block (RFC 7541 §4.2: only at the beginning).
    case misplacedTableSizeUpdate
    /// The block didn't start with the size update a lowered SETTINGS_HEADER_TABLE_SIZE requires (RFC 7541 §4.2).
    case missingTableSizeUpdate
    /// The fields' size (name + value + 32 each, RFC 7541 §4.1) passed the decoder's limit, or a field didn't fit the
    /// encoder's output.
    case headerListTooLarge
    /// The encoder's output is full.
    case outputTooSmall
    /// A field HTTP/2 doesn't allow (``HPACKDecoder/decode(_:into:)``):
    /// characters RFC 9113 §8.2.1 forbids (an uppercase or non-token name, an unknown pseudo-header field, a value with
    /// NUL, CR, or LF, or with whitespace at its ends), or a connection-specific field (§8.2.2: `connection`,
    /// `keep-alive`, `proxy-connection`, `transfer-encoding`, `upgrade`, or `te` other than `trailers`). The message is
    /// malformed, a stream error of type PROTOCOL_ERROR (§8.1.1); the decoder has decoded the rest of the block, so its
    /// table is in step.
    case malformedField
    /// A call that doesn't continue the block in progress (a programming error; the table may have missed the rest of a
    /// block): ``HPACKDecoder/next(in:)`` or ``HPACKDecoder/skipRest(of:)`` given another block (another address or
    /// length) before the block ended, `next(in:)` called again after it threw (finish the block with
    /// ``HPACKDecoder/skipRest(of:)`` after ``headerListTooLarge``, or start over with ``HPACKDecoder/resetBlock()``), or
    /// `skipRest(of:)` after an error that lost the compression state.
    case unfinishedBlock

    /// The HTTP/2 error to answer with: COMPRESSION_ERROR for the connection, except for ``headerListTooLarge``, which
    /// is a stream's (REFUSED_STREAM is what RFC 9113 §8.7 suggests for a request a server won't process; a server can
    /// instead answer 431), and ``malformedField``, a stream's PROTOCOL_ERROR. ``outputTooSmall`` and
    /// ``unfinishedBlock`` are this endpoint's own conditions: INTERNAL_ERROR if they end the connection.
    @inlinable
    public func http2Error(stream: HTTP2StreamID) -> HTTP2Error {
        switch self {
        case .headerListTooLarge: .stream(stream, .refusedStream)
        case .malformedField: .stream(stream, .protocolError)
        case .outputTooSmall, .unfinishedBlock: .connection(.internalError)
        default: .connection(.compressionError)
        }
    }
}
