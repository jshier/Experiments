public import Bytes

/// A field block's fragments joined: HEADERS (or PUSH_PROMISE) without END_HEADERS, then its CONTINUATION frames
/// (RFC 9113 §6.10), for ``HPACKDecoder/next(in:)``, which takes a whole block.
///
/// ```swift
/// case .headers(let stream, let fragment, _, let endHeaders, _):
///     if endHeaders { decode(fragment) } else { try pending.append(fragment) }
/// case .continuation(_, let fragment, let endHeaders):
///     try pending.append(fragment)
///     if endHeaders { decode(pending.block); pending.removeAll() }
/// ```
///
/// A block in one frame (the usual case) is decoded where it is; only blocks split across frames are copied, once. The
/// memory is kept between blocks: nothing allocated once it has grown to the largest block.
///
/// **CONTINUATION floods** (CVE-2024-27316, -27983, -28182, -31309, and others: endless CONTINUATION frames, empty or
/// not, that a peer never ends) are limited two ways: the block's bytes (``maximumByteCount``) and its fragments
/// (``maximumFragmentCount``), the HEADERS frame's included. Every fragment counts, empty ones too: they cost a frame's
/// processing and carry nothing.
public struct HTTP2FieldBlockBuffer: Sendable {
    @usableFromInline var bytes: [UInt8] = []
    /// The fragments appended since the last ``removeAll()``.
    @usableFromInline var fragmentCount = 0
    /// The largest block accepted.
    public let maximumByteCount: Int
    /// The most fragments a block may have: its HEADERS or PUSH_PROMISE frame and its CONTINUATION frames.
    public let maximumFragmentCount: Int

    /// A buffer for blocks up to `maximumByteCount` bytes (a limit against CONTINUATION floods: twice the header list
    /// limit is generous, since a field's representation is at most a few bytes more than the field) and
    /// `maximumFragmentCount` fragments (64: a block of 1 MiB in default-size frames is 64 fragments, and peers send one
    /// or two).
    @inlinable
    public init(maximumByteCount: Int = 1 << 20, maximumFragmentCount: Int = 64) {
        precondition(maximumFragmentCount >= 1, "a block has at least one fragment")
        self.maximumByteCount = maximumByteCount
        self.maximumFragmentCount = maximumFragmentCount
    }

    /// The joined block.
    @inlinable
    public var block: RawSpan {
        @_lifetime(borrow self) get { bytes.span.bytes }
    }

    /// Whether no fragment is held (an empty fragment counts as one).
    @inlinable
    public var isEmpty: Bool { fragmentCount == 0 }

    /// The fragments held.
    @inlinable
    public var count: Int { fragmentCount }

    /// Appends a fragment (an empty one too: it counts against ``maximumFragmentCount``).
    ///
    /// - Throws: ENHANCE_YOUR_CALM for the connection if the block would pass ``maximumByteCount`` or
    ///   ``maximumFragmentCount``.
    @inlinable
    public mutating func append(_ fragment: RawSpan) throws(HTTP2Error) {
        guard fragmentCount < maximumFragmentCount, fragment.byteCount <= maximumByteCount &- bytes.count else {
            throw .connection(.enhanceYourCalm)
        }
        fragmentCount &+= 1
        bytes.append(copying: fragment)
    }

    /// Empties the buffer for the next block, keeping its memory.
    @inlinable
    public mutating func removeAll() {
        bytes.removeAll(keepingCapacity: true)
        fragmentCount = 0
    }
}
