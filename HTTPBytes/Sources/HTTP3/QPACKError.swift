public import HTTPBytes

/// Why QPACK (RFC 9204) couldn't decode a field section or an instruction stream, or couldn't encode. Payload-free, so
/// throwing allocates nothing.
///
/// ``http3Error`` gives the error to close the connection with: QPACK_DECOMPRESSION_FAILED for a field section,
/// QPACK_ENCODER_STREAM_ERROR for the encoder stream, QPACK_DECODER_STREAM_ERROR for the decoder stream (RFC 9204 §6).
/// ``fieldSectionTooLarge`` and ``malformedField`` are the stream's alone, and ``decoderStreamFull``, ``outputTooSmall``,
/// and ``sectionNotBegun`` are this endpoint's conditions, not the peer's errors.
@frozen
public enum QPACKError: Error, Sendable, Hashable {
    // A field section (QPACK_DECOMPRESSION_FAILED).

    /// The section ends inside a representation (a truncated integer or string), or before its prefix ends.
    case truncated
    /// A static index past the table's 99 entries, or a dynamic reference to an entry evicted, not yet inserted, or at or
    /// past the section's Required Insert Count (RFC 9204 §2.2.3, §3.1).
    case invalidIndex
    /// An integer past 2⁶² − 1 (RFC 9204 §4.1.1).
    case integerOverflow
    /// A Huffman-coded string with EOS in it, or padding longer than 7 bits or not all ones (RFC 7541 §5.2).
    case invalidHuffmanCode
    /// A Required Insert Count no conformant encoder could have sent, or larger than the section needed (RFC 9204
    /// §2.2.1, §4.5.1.1).
    case invalidRequiredInsertCount
    /// A negative Base: Sign set with a Delta Base of at least the Required Insert Count (RFC 9204 §4.5.1.2).
    case invalidBase
    /// A section would block more streams than SETTINGS_QPACK_BLOCKED_STREAMS allows (RFC 9204 §2.1.2).
    case tooManyBlockedStreams

    // A field section, the stream's alone.

    /// The fields' size (name + value + 32 each) passed the decoder's limit, SETTINGS_MAX_FIELD_SECTION_SIZE (RFC 9114
    /// §4.2.2). The section is abandoned: reset the stream (and call ``QPACKDecoder/cancelStream(_:)``).
    case fieldSectionTooLarge
    /// A field's name or value has characters HTTP/3 forbids (RFC 9114 §4.2: an uppercase letter, control, space, or
    /// colon past the first byte in a name; NUL, CR, or LF in a value, or whitespace at its ends): the message is
    /// malformed, a stream error (H3_MESSAGE_ERROR, §4.1.2). Thrown by ``QPACKDecoder/decode(_:stream:into:)``; the
    /// section is abandoned, as for ``fieldSectionTooLarge``.
    case malformedField

    // The encoder stream (QPACK_ENCODER_STREAM_ERROR).

    /// An instruction the decoder can't apply: a reference to an entry evicted or not inserted, a static index past the
    /// table, an integer past 2⁶² − 1, or a Huffman-coded string that doesn't decode (RFC 9204 §2.2.3, §4.3).
    case invalidEncoderInstruction
    /// Set Dynamic Table Capacity above SETTINGS_QPACK_MAX_TABLE_CAPACITY (RFC 9204 §4.3.1).
    case tableCapacityTooLarge
    /// An insertion larger than the table's capacity (RFC 9204 §3.2.2).
    case entryTooLarge

    // The decoder stream (QPACK_DECODER_STREAM_ERROR).

    /// A Section Acknowledgment for a stream with no unacknowledged section, an Insert Count Increment of zero or past the
    /// insertions sent, or an integer past 2⁶² − 1 (RFC 9204 §4.4).
    case invalidDecoderInstruction

    // This endpoint's conditions.

    /// The decoder's instruction buffer has no room for the acknowledgment this section would need: write the pending
    /// instructions (``QPACKDecoder/writeDecoderInstructions(into:)``) and call again. Nothing changed.
    case decoderStreamFull
    /// The encoder's output (a field section or the encoder stream) is full.
    case outputTooSmall
    /// ``QPACKDecoder/next(in:)`` was called with no section begun: before ``QPACKDecoder/begin(_:stream:)`` returned
    /// `true`, or after the section's end or an error. A mistake in the caller, thrown rather than trapping.
    case sectionNotBegun

    /// The HTTP/3 error to answer with (RFC 9204 §6): a connection error with the QPACK code, except
    /// ``fieldSectionTooLarge`` (a stream error, H3_EXCESSIVE_LOAD: or answer 431), ``malformedField`` (a stream error,
    /// H3_MESSAGE_ERROR), and this endpoint's own conditions (``outputTooSmall``, ``decoderStreamFull``, and
    /// ``sectionNotBegun``: H3_INTERNAL_ERROR, if they end the connection).
    @inlinable
    public var http3Error: HTTP3Error {
        switch self {
        case .truncated, .invalidIndex, .integerOverflow, .invalidHuffmanCode, .invalidRequiredInsertCount, .invalidBase,
             .tooManyBlockedStreams:
            .connection(.qpackDecompressionFailed)
        case .fieldSectionTooLarge: .stream(.excessiveLoad)
        case .malformedField: .stream(.messageError)
        case .invalidEncoderInstruction, .tableCapacityTooLarge, .entryTooLarge: .connection(.qpackEncoderStreamError)
        case .invalidDecoderInstruction: .connection(.qpackDecoderStreamError)
        case .decoderStreamFull, .outputTooSmall, .sectionNotBegun: .connection(.internalError)
        }
    }

    /// A code for the decoder's step result: 16 and up.
    @inlinable
    var code: UInt8 {
        switch self {
        case .truncated: 16
        case .invalidIndex: 17
        case .integerOverflow: 18
        case .invalidHuffmanCode: 19
        case .invalidRequiredInsertCount: 20
        case .invalidBase: 21
        case .tooManyBlockedStreams: 22
        case .fieldSectionTooLarge: 23
        case .invalidEncoderInstruction: 24
        case .tableCapacityTooLarge: 25
        case .entryTooLarge: 26
        case .invalidDecoderInstruction: 27
        case .decoderStreamFull: 28
        case .outputTooSmall: 29
        case .malformedField: 30
        case .sectionNotBegun: 31
        }
    }

    @inlinable
    init(code: UInt8) {
        switch code {
        case 16: self = .truncated
        case 17: self = .invalidIndex
        case 18: self = .integerOverflow
        case 19: self = .invalidHuffmanCode
        case 20: self = .invalidRequiredInsertCount
        case 21: self = .invalidBase
        case 22: self = .tooManyBlockedStreams
        case 23: self = .fieldSectionTooLarge
        case 24: self = .invalidEncoderInstruction
        case 25: self = .tableCapacityTooLarge
        case 26: self = .entryTooLarge
        case 27: self = .invalidDecoderInstruction
        case 28: self = .decoderStreamFull
        case 30: self = .malformedField
        case 31: self = .sectionNotBegun
        default: self = .outputTooSmall
        }
    }
}

/// QPACK's field-section rules are HTTP/2's (RFC 9114 §4.2–4.3): the core's ``HTTPFieldSectionError``.
public typealias HTTP3FieldError = HTTPFieldSectionError

/// Checks an HTTP/3 field section (RFC 9114 §4.2–4.3): the core's ``HTTPFieldSectionValidator``, shared with HTTP/2,
/// which checks ``QPACKField``s with the decoder's verdict on their characters.
public typealias HTTP3FieldValidator = HTTPFieldSectionValidator

/// How the QPACK encoder may use the dynamic table for a field: the core's ``HTTPFieldIndexingStrategy``, shared with HPACK.
public typealias QPACKIndexingStrategy = HTTPFieldIndexingStrategy

extension HTTPFieldSectionError {
    /// The stream error to answer with: H3_MESSAGE_ERROR (RFC 9114 §4.1.2).
    @inlinable
    public var http3Error: HTTP3Error { .stream(.messageError) }
}
