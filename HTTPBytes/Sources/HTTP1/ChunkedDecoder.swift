public import Bytes
public import HTTPBytes

/// What ``HTTP1ChunkedDecoder/next(in:consumed:)`` found.
public enum HTTP1ChunkEvent: ~Escapable {
    /// Body bytes: a slice of the input, never copied.
    case data(RawSpan)
    /// A trailer field (RFC 9112 §7.1.2), after the last chunk.
    case trailer(HTTPFieldView)
    /// The body's end: the chunked coding's last byte has been consumed.
    case end
    /// The input ends before the next event does.
    case needsMore
}

/// Chunked transfer coding (RFC 9112 §7.1), decoded without copying: each ``HTTP1ChunkEvent/data(_:)`` is a slice of the
/// bytes given, from which the caller reads (or hands to a content decoder) directly.
///
/// ```swift
/// var decoder = HTTP1ChunkedDecoder()
/// var consumed = 0
/// loop: while true {
///     switch try decoder.next(in: unread, consumed: &consumed) {
///     case .data(let bytes): consume(bytes)
///     case .trailer(let field): …
///     case .end: break loop
///     case .needsMore: unread = await more(after: unread, dropping: consumed); continue loop
///     }
///     unread = unread.extracting(droppingFirst: consumed)
/// }
/// ```
///
/// Each call takes the body bytes not yet consumed, and reports how many of them its event used: drop them before the
/// next call. Chunk-size lines (hexadecimal size, then extensions, which are checked for control characters and their
/// length limit, and ignored) and the CR LF after each chunk's data are consumed along with the data event that
/// follows them, so a call returns data whenever there is some.
@frozen
public struct HTTP1ChunkedDecoder: Sendable {
    /// The most bytes of chunk extensions on one chunk-size line (RFC 9112 §7.1.1 lets a recipient limit them; they're
    /// a way to make a server buffer without limit otherwise).
    public var maximumExtensionByteCount: Int
    /// Whether lines may end in a bare LF.
    public var allowsBareLineFeed: Bool
    /// The most trailer fields.
    public var maximumTrailerCount: Int
    /// The most bytes of chunk extensions in a whole body.
    public var maximumTotalExtensionByteCount: Int
    @usableFromInline var extensionByteCount = 0
    /// The most bytes the trailer section may have (``HTTP1Error/headTooLarge`` beyond it; 16 KiB by default).
    public var maximumTrailerSectionByteCount = 16_384
    @usableFromInline var trailerByteCount = 0

    @usableFromInline var remaining = 0
    @usableFromInline var phase = Phase.size
    @usableFromInline var trailerCount = 0

    @frozen @usableFromInline
    enum Phase: Sendable { case size, data, dataEnd, trailers, done }

    @inlinable
    public init(maximumExtensionByteCount: Int = 4096, maximumTotalExtensionByteCount: Int = 16_384, allowsBareLineFeed: Bool = false,
                maximumTrailerCount: Int = 64) {
        self.maximumExtensionByteCount = maximumExtensionByteCount
        self.maximumTotalExtensionByteCount = maximumTotalExtensionByteCount
        self.allowsBareLineFeed = allowsBareLineFeed
        self.maximumTrailerCount = maximumTrailerCount
    }

    /// The next event in `bytes`, the body's bytes not yet consumed.
    ///
    /// - Parameters:
    ///   - bytes: The unconsumed bytes.
    ///   - consumed: Set to how many of `bytes` the event used (0 for ``HTTP1ChunkEvent/needsMore``).
    @inlinable
    @_lifetime(copy bytes)
    public mutating func next(in bytes: RawSpan, consumed: inout Int) throws(HTTP1Error) -> HTTP1ChunkEvent {
        let count = bytes.byteCount
        var position = 0
        consumed = 0
        while true {
            switch phase {
            case .size:
                guard let (size, next) = try sizeLine(bytes, at: position) else {
                    // What this call consumed before the size line (the CR LF after the last chunk's data).
                    consumed = position
                    return .needsMore
                }
                // Lines are short without extensions (the size, CR LF): what's beyond 18 bytes counts toward the
                // body's limit (RFC 9112 §7.1.1: a recipient ought to limit the total, not only each line's).
                extensionByteCount &+= Swift.max(0, next &- position &- 18)
                guard extensionByteCount <= maximumTotalExtensionByteCount else { throw .chunkExtensionsTooLong }
                position = next
                remaining = size
                phase = size == 0 ? .trailers : .data
            case .data:
                guard position < count else {
                    // A size line consumed, its data not here yet.
                    consumed = position
                    return .needsMore
                }
                let take = Swift.min(remaining, count &- position)
                remaining &-= take
                if remaining == 0 { phase = .dataEnd }
                consumed = position &+ take
                return .data(bytes.extracting(position..<position &+ take))
            case .dataEnd:
                guard position &+ 2 <= count else {
                    if position < count, bytes.byte(position) != .cr, !(allowsBareLineFeed && bytes.byte(position) == .lf) {
                        throw .invalidChunkEnd
                    }
                    if allowsBareLineFeed, position < count, bytes.byte(position) == .lf {
                        position &+= 1
                        phase = .size
                        continue
                    }
                    consumed = position
                    return .needsMore
                }
                if bytes.byte(position) == .cr, bytes.byte(position &+ 1) == .lf {
                    position &+= 2
                } else if allowsBareLineFeed, bytes.byte(position) == .lf {
                    position &+= 1
                } else {
                    throw .invalidChunkEnd
                }
                phase = .size
            case .trailers:
                var scanner = HeadScanner()
                switch try scanner.fieldLine(bytes, at: position, allowsBareLineFeed: allowsBareLineFeed) {
                case let .field(nameEnd, valueStart, valueEnd, next):
                    guard trailerCount < maximumTrailerCount else { throw .tooManyFields }
                    trailerByteCount &+= next &- position
                    guard trailerByteCount <= maximumTrailerSectionByteCount else { throw .headTooLarge }
                    trailerCount &+= 1
                    consumed = next
                    let name = bytes.extracting(position..<nameEnd)
                    return .trailer(HTTPFieldView(name: name, value: bytes.extracting(valueStart..<valueEnd),
                                                  knownName: HTTPFieldName(caseInsensitive: name)))
                case let .end(next):
                    phase = .done
                    consumed = next
                    return .end
                case .needsMore:
                    // A trailer line that hasn't ended yet counts too: otherwise one endless line would be buffered forever.
                    guard trailerByteCount &+ (count &- position) <= maximumTrailerSectionByteCount else { throw .headTooLarge }
                    consumed = position
                    return .needsMore
                }
            case .done:
                return .end
            }
        }
    }

    /// A chunk-size line at `start`: its size and the offset after it, or `nil` if it isn't all there.
    @inlinable
    func sizeLine(_ bytes: RawSpan, at start: Int) throws(HTTP1Error) -> (Int, Int)? {
        let count = bytes.byteCount
        var position = start
        var size = 0
        while position < count {
            let byte = bytes.byte(position)
            let digit: UInt8
            if byte &- 0x30 < 10 { digit = byte &- 0x30 }
            else if (byte | 0x20) &- 0x61 < 6 { digit = (byte | 0x20) &- 0x61 &+ 10 }
            else { break }
            // 15 hexadecimal digits at most: no overflow, and no chunk anyone can send is larger.
            guard position &- start < 15 else { throw .invalidChunkSize }
            size = size &<< 4 | Int(digit)
            position &+= 1
        }
        guard position < count else { return nil }
        guard position > start else { throw .invalidChunkSize }
        // Extensions or the line end.
        let first = bytes.byte(position)
        if first != .cr && first != .lf {
            guard let end = try Self.extensionsEnd(bytes, from: position, limit: maximumExtensionByteCount) else { return nil }
            position = end
        }
        switch bytes.byte(position) {
        case .cr:
            guard position &+ 1 < count else { return nil }
            guard bytes.byte(position &+ 1) == .lf else { throw .invalidChunkSize }
            return (size, position &+ 2)
        case .lf:
            guard allowsBareLineFeed else { throw .invalidChunkSize }
            return (size, position &+ 1)
        default:
            throw .invalidChunkSize
        }
    }

    /// The offset of the CR (or LF) ending a size line's extensions that start at `start`, checked against RFC 9112
    /// §7.1.1's grammar: `*( BWS ";" BWS ext-name [ BWS "=" BWS ext-val ] )`, a name a token, a value a token or a
    /// quoted string; whitespace only before a `;` or around `=` (so `a \r\n` is malformed, as llhttp holds). `nil` if
    /// the bytes end first; at most `limit` bytes. Out of line: extensions are rare, and this keeps the decode loop small.
    @usableFromInline
    static func extensionsEnd(_ bytes: RawSpan, from start: Int, limit: Int) throws(HTTP1Error) -> Int? {
        let end = Swift.min(bytes.byteCount, start &+ limit &+ 1)
        var position = start
        @inline(__always) func skipWhitespace() {
            while position < end, case let byte = bytes.byte(position), byte == .space || byte == .tab { position &+= 1 }
        }
        @inline(__always) func token() -> Int {
            let first = position
            while position < end, isTokenByte(bytes.byte(position)) { position &+= 1 }
            return position &- first
        }
        while true {
            let beforeWhitespace = position
            skipWhitespace()
            guard position < end else { break }
            let byte = bytes.byte(position)
            if byte == .cr || byte == .lf {
                // The line's end, but not after whitespace that no `;` followed.
                guard position == beforeWhitespace else { throw .invalidChunkSize }
                return position
            }
            guard byte == 0x3B else { throw .invalidChunkSize }
            position &+= 1
            skipWhitespace()
            guard token() > 0 || position == end else { throw .invalidChunkSize }
            // Whitespace after a name only before `=` (BWS "=" BWS); otherwise it's left for the loop's check, which
            // allows it only before a `;`.
            let afterName = position
            skipWhitespace()
            guard position < end else { break }
            guard bytes.byte(position) == 0x3D else {
                position = afterName
                continue
            }
            position &+= 1
            skipWhitespace()
            guard position < end else { break }
            if bytes.byte(position) == 0x22 {
                // quoted-string: qdtext (tab, space, 0x21, 0x23–0x5B, 0x5D–0x7E, 0x80–0xFF) or a backslash pair.
                position &+= 1
                var closed = false
                while position < end {
                    let character = bytes.byte(position)
                    if character == 0x22 { position &+= 1; closed = true; break }
                    if character == 0x5C {
                        guard position &+ 1 < end else { position = end; break }
                        let escaped = bytes.byte(position &+ 1)
                        guard escaped == .tab || escaped >= 0x20 && escaped != 0x7F else { throw .invalidChunkSize }
                        position &+= 2
                        continue
                    }
                    guard character == .tab || character >= 0x20 && character != 0x7F else { throw .invalidChunkSize }
                    position &+= 1
                }
                if !closed { break }
            } else {
                guard token() > 0 || position == end else { throw .invalidChunkSize }
            }
        }
        // The bytes ran out (or the limit): more may come, unless the limit was reached.
        guard end &- start <= limit else { throw .chunkExtensionsTooLong }
        return nil
    }

    /// Whether `byte` is a token character (RFC 9110 §5.6.2).
    @inlinable @inline(__always)
    static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: true
        case 0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x5E, 0x5F, 0x60, 0x7C, 0x7E: true
        default: false
        }
    }
}

/// Chunked transfer coding's writing side: a chunk's size line before its data, and the last chunk.
public enum HTTP1ChunkedEncoder {
    /// Writes the size line for a chunk of `byteCount` bytes (`byteCount > 0`): lowercase hexadecimal, then CR LF (at
    /// most 18 bytes).
    @inlinable
    public static func writeSizeLine(_ byteCount: Int, to writer: inout AlignedBytesWriter) throws(BytesError) {
        precondition(byteCount > 0, "a chunk's size; the last chunk is `writeLastChunk`")
        let digits = (Int.bitWidth &- byteCount.leadingZeroBitCount &+ 3) / 4
        var shift = (digits &- 1) &* 4
        while shift >= 0 {
            let nibble = UInt8(truncatingIfNeeded: byteCount &>> shift) & 0xF
            try writer.write(nibble < 10 ? 0x30 &+ nibble : 0x61 &+ nibble &- 10)
            shift &-= 4
        }
        try writer.write(0x0A0D as UInt16, as: Byte2.self, .littleEndian)
    }

    /// Writes the CR LF after a chunk's data.
    @inlinable
    public static func writeChunkEnd(to writer: inout AlignedBytesWriter) throws(BytesError) {
        try writer.write(0x0A0D as UInt16, as: Byte2.self, .littleEndian)
    }

    /// Writes the last chunk and an empty trailer section: `0` CR LF CR LF.
    @inlinable
    public static func writeLastChunk(to writer: inout AlignedBytesWriter) throws(BytesError) {
        try writer.write(0x30 as UInt8)
        try writer.write(0x0A0D_0A0D as UInt32, as: Byte4.self, .littleEndian)
    }
}
