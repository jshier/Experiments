public import Bytes

/// A frame, as parsed: its fields as values and its payload as views of the bytes (RFC 9113 §6, RFC 9218 §7.1).
/// Padding is removed (and checked); the flow-controlled length of DATA (padding included, §6.1) is reported.
public enum HTTP2Frame: ~Escapable {
    /// DATA: `payload` without padding; `flowControlledByteCount` is the whole frame payload, which counts against flow
    /// control windows.
    case data(stream: HTTP2StreamID, payload: RawSpan, endStream: Bool, flowControlledByteCount: Int)
    /// HEADERS: a field block fragment (HPACK; complete when `endHeaders`, else CONTINUATION frames follow).
    case headers(stream: HTTP2StreamID, fieldBlock: RawSpan, endStream: Bool, endHeaders: Bool, priority: HTTP2Priority?)
    /// HEADERS whose stream must be reset with `error` (RST_STREAM; RFC 9113 §5.4.2), but whose field block must still
    /// be decoded, with the CONTINUATION frames that follow when not `endHeaders`, to keep the HPACK table in step with
    /// the peer's (RFC 9113 §4.3: a receiver that doesn't decode a block loses the connection's compression state).
    /// Decode it and discard its fields: don't act on the request or response. Today, a priority that makes the stream
    /// depend on itself (RFC 9113 §5.3.1: a stream error of type PROTOCOL_ERROR).
    ///
    /// A case of its own rather than a flag on ``headers(stream:fieldBlock:endStream:endHeaders:priority:)``, so it can't
    /// be processed as a request by a caller that doesn't look; one that ignores it altogether leaves the block
    /// undecoded, and its decoder then fails loudly (COMPRESSION_ERROR, or ``HPACKError/unfinishedBlock``) rather than
    /// quietly.
    case rejectedHeaders(stream: HTTP2StreamID, fieldBlock: RawSpan, endHeaders: Bool, error: HTTP2Error)
    /// PRIORITY (deprecated; parsed and checked).
    case priority(stream: HTTP2StreamID, HTTP2Priority)
    /// RST_STREAM.
    case resetStream(stream: HTTP2StreamID, HTTP2ErrorCode)
    /// SETTINGS: an acknowledgment, or settings to read with ``HTTP2SettingsPayload``.
    case settings(HTTP2SettingsPayload)
    /// PUSH_PROMISE.
    case pushPromise(stream: HTTP2StreamID, promisedStream: HTTP2StreamID, fieldBlock: RawSpan, endHeaders: Bool)
    /// PING, with its 8 bytes as a big-endian integer.
    case ping(ack: Bool, opaqueData: UInt64)
    /// GOAWAY.
    case goaway(lastStream: HTTP2StreamID, HTTP2ErrorCode, debugData: RawSpan)
    /// WINDOW_UPDATE (stream 0: the connection's window).
    case windowUpdate(stream: HTTP2StreamID, increment: UInt32)
    /// CONTINUATION: the next fragment of a field block.
    case continuation(stream: HTTP2StreamID, fieldBlock: RawSpan, endHeaders: Bool)
    /// PRIORITY_UPDATE (RFC 9218): a `Priority` field value (Structured Fields) for a stream.
    case priorityUpdate(prioritizedStream: HTTP2StreamID, priorityFieldValue: RawSpan)
    /// A frame type this module doesn't know (RFC 9113 §5.5: ignore it).
    case unknown(type: HTTP2FrameType, flags: HTTP2FrameFlags, stream: HTTP2StreamID, payload: RawSpan)
    /// The bytes end before the frame does.
    case needsMore
}

/// A SETTINGS frame's payload: 6-byte entries, read one at a time.
@frozen
public struct HTTP2SettingsPayload: ~Escapable {
    /// Whether this is an acknowledgment (empty).
    public let isAcknowledgment: Bool
    /// The entries' bytes.
    public let entries: RawSpan

    @inlinable @inline(__always)
    @_lifetime(copy entries)
    init(isAcknowledgment: Bool, entries: RawSpan) {
        self.isAcknowledgment = isAcknowledgment
        self.entries = entries
    }

    /// How many settings.
    @inlinable public var count: Int { entries.byteCount / 6 }

    /// Setting `index`: its identifier and value.
    @inlinable
    public func setting(at index: Int) -> (id: HTTP2SettingID, value: UInt32) {
        let offset = index &* 6
        let id = UInt16(bigEndian: entries.load(fromByteOffset: offset, as: UInt16.self))
        let value = UInt32(bigEndian: entries.load(fromByteOffset: offset &+ 2, as: UInt32.self))
        return (HTTP2SettingID(rawValue: id), value)
    }

    /// Applies every setting to `settings`, in order, checking each (RFC 9113 §6.5.2–3).
    @inlinable
    public func apply(to settings: inout HTTP2Settings) throws(HTTP2Error) {
        for index in 0..<count {
            let (id, value) = setting(at: index)
            try settings.apply(id, value)
        }
    }
}

/// The client connection preface (RFC 9113 §3.4): `PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n`, 24 bytes, before the client's
/// first SETTINGS frame.
public enum HTTP2ConnectionPreface {
    /// The preface's bytes.
    public static var bytes: StaticString { "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" }

    /// Whether `bytes` start with the preface: `true`, `false` (not HTTP/2: answer as HTTP/1 or close), or `nil` if
    /// they're a prefix of it so far.
    @inlinable
    public static func matches(_ bytes: RawSpan) -> Bool? {
        let preface = Self.bytes.bytes
        let count = Swift.min(bytes.byteCount, 24)
        guard bytes.extracting(0..<count).bytesEqual(preface.extracting(0..<count)) else { return false }
        return count == 24 ? true : nil
    }
}

/// HTTP/2 frames from bytes (RFC 9113 §4–6): each call parses one frame, checks it as §6 says (sizes, stream 0 or
/// not, padding, field blocks continued only by CONTINUATION on their stream), and returns it as views.
///
/// ```swift
/// var parser = HTTP2FrameParser()
/// var consumed = 0
/// switch try parser.next(in: unread, consumed: &consumed) {
/// case .headers(let stream, let block, let endStream, let endHeaders, _): …
/// case .rejectedHeaders(let stream, let block, let endHeaders, let error): …   // decode the block, discard it, reset the stream
/// case .data(let stream, let payload, let endStream, _): …
/// …
/// }
/// unread = unread.extracting(droppingFirst: consumed)
/// ```
///
/// It checks each frame alone and the CONTINUATION sequence; stream states, flow-control windows, and which side may
/// send what are the connection's to track. It allocates nothing.
@frozen
public struct HTTP2FrameParser: Sendable {
    /// The largest frame payload accepted: the SETTINGS_MAX_FRAME_SIZE this endpoint advertised (16,384 until it says
    /// otherwise).
    public var maximumFrameSize: Int
    /// The stream whose field block a CONTINUATION must continue, or 0.
    @usableFromInline var continuing: UInt32 = 0

    @inlinable
    public init(maximumFrameSize: Int = 16_384) {
        self.maximumFrameSize = maximumFrameSize
    }

    /// The next frame in `bytes` (the unconsumed bytes).
    ///
    /// - Parameter consumed: Set to the frame's size (header and payload), or 0 for ``HTTP2Frame/needsMore``. Also set
    ///   when a stream error is thrown (``HTTP2Error/stream(_:_:)``): reset that stream and go on after the frame.
    ///   (After a connection error, nothing follows.)
    @inlinable
    @_lifetime(copy bytes)
    public mutating func next(in bytes: RawSpan, consumed: inout Int) throws(HTTP2Error) -> HTTP2Frame {
        consumed = 0
        guard bytes.byteCount >= 9 else { return .needsMore }
        // Length (24), type (8), flags (8) in the first 5 bytes; R and the stream identifier in the next 4.
        let first = UInt64(bigEndian: bytes.load(fromByteOffset: 0, as: UInt64.self))
        let length = Int(truncatingIfNeeded: first &>> 40)
        let type = HTTP2FrameType(rawValue: UInt8(truncatingIfNeeded: first &>> 32))
        let flags = HTTP2FrameFlags(rawValue: UInt8(truncatingIfNeeded: first &>> 24))
        let streamValue = UInt32(bigEndian: bytes.load(fromByteOffset: 5, as: UInt32.self)) & 0x7FFF_FFFF
        let stream = HTTP2StreamID(uncheckedRawValue: streamValue)
        guard length <= maximumFrameSize else { throw .connection(.frameSizeError) }
        guard bytes.byteCount &- 9 >= length else { return .needsMore }
        let payload = bytes.extracting(9..<9 &+ length)
        // Before any check: a stream error leaves the connection going, and its caller must skip the frame.
        consumed = 9 &+ length
        // Inside a field block, only its CONTINUATION frames (§6.10).
        if continuing != 0, type != .continuation || streamValue != continuing { throw .connection(.protocolError) }
        let frame: HTTP2Frame
        switch type {
        case .data:
            guard streamValue != 0 else { throw .connection(.protocolError) }
            let content = try Self.unpadded(payload, flags)
            frame = .data(stream: stream, payload: content, endStream: flags.contains(.endStream), flowControlledByteCount: length)
        case .headers:
            guard streamValue != 0 else { throw .connection(.protocolError) }
            var content = try Self.unpadded(payload, flags)
            var priority: HTTP2Priority?
            var rejection: HTTP2Error?
            if flags.contains(.priority) {
                guard content.byteCount >= 5 else { throw .connection(.frameSizeError) }
                do throws(HTTP2Error) {
                    priority = try Self.priority(content, of: stream)
                } catch {
                    // The block is still the HPACK decoder's (§4.3): returned, with the stream's error.
                    rejection = error
                }
                content = content.extracting(droppingFirst: 5)
            }
            let endHeaders = flags.contains(.endHeaders)
            if !endHeaders { continuing = streamValue }
            if let rejection {
                frame = .rejectedHeaders(stream: stream, fieldBlock: content, endHeaders: endHeaders, error: rejection)
            } else {
                frame = .headers(stream: stream, fieldBlock: content, endStream: flags.contains(.endStream), endHeaders: endHeaders,
                                 priority: priority)
            }
        case .priority:
            guard streamValue != 0 else { throw .connection(.protocolError) }
            guard length == 5 else { throw .stream(stream, .frameSizeError) }
            frame = try .priority(stream: stream, Self.priority(payload, of: stream))
        case .rstStream:
            guard streamValue != 0 else { throw .connection(.protocolError) }
            guard length == 4 else { throw .connection(.frameSizeError) }
            frame = .resetStream(stream: stream, HTTP2ErrorCode(rawValue: UInt32(bigEndian: payload.load(fromByteOffset: 0, as: UInt32.self))))
        case .settings:
            guard streamValue == 0 else { throw .connection(.protocolError) }
            let ack = flags.contains(.ack)
            guard ack ? length == 0 : length % 6 == 0 else { throw .connection(.frameSizeError) }
            frame = .settings(HTTP2SettingsPayload(isAcknowledgment: ack, entries: payload))
        case .pushPromise:
            guard streamValue != 0 else { throw .connection(.protocolError) }
            let content = try Self.unpadded(payload, flags)
            guard content.byteCount >= 4 else { throw .connection(.frameSizeError) }
            let promised = UInt32(bigEndian: content.load(fromByteOffset: 0, as: UInt32.self)) & 0x7FFF_FFFF
            let endHeaders = flags.contains(.endHeaders)
            if !endHeaders { continuing = streamValue }
            frame = .pushPromise(stream: stream, promisedStream: HTTP2StreamID(uncheckedRawValue: promised),
                                 fieldBlock: content.extracting(droppingFirst: 4), endHeaders: endHeaders)
        case .ping:
            guard streamValue == 0 else { throw .connection(.protocolError) }
            guard length == 8 else { throw .connection(.frameSizeError) }
            frame = .ping(ack: flags.contains(.ack), opaqueData: UInt64(bigEndian: payload.load(fromByteOffset: 0, as: UInt64.self)))
        case .goaway:
            guard streamValue == 0 else { throw .connection(.protocolError) }
            guard length >= 8 else { throw .connection(.frameSizeError) }
            let last = UInt32(bigEndian: payload.load(fromByteOffset: 0, as: UInt32.self)) & 0x7FFF_FFFF
            let code = UInt32(bigEndian: payload.load(fromByteOffset: 4, as: UInt32.self))
            frame = .goaway(lastStream: HTTP2StreamID(uncheckedRawValue: last), HTTP2ErrorCode(rawValue: code),
                            debugData: payload.extracting(droppingFirst: 8))
        case .windowUpdate:
            guard length == 4 else { throw .connection(.frameSizeError) }
            let increment = UInt32(bigEndian: payload.load(fromByteOffset: 0, as: UInt32.self)) & 0x7FFF_FFFF
            guard increment != 0 else { throw streamValue == 0 ? .connection(.protocolError) : .stream(stream, .protocolError) }
            frame = .windowUpdate(stream: stream, increment: increment)
        case .continuation:
            guard continuing != 0 else { throw .connection(.protocolError) }
            let endHeaders = flags.contains(.endHeaders)
            if endHeaders { continuing = 0 }
            frame = .continuation(stream: stream, fieldBlock: payload, endHeaders: endHeaders)
        case .priorityUpdate:
            guard streamValue == 0 else { throw .connection(.protocolError) }
            guard length >= 4 else { throw .connection(.frameSizeError) }
            let prioritized = UInt32(bigEndian: payload.load(fromByteOffset: 0, as: UInt32.self)) & 0x7FFF_FFFF
            guard prioritized != 0 else { throw .connection(.protocolError) }
            frame = .priorityUpdate(prioritizedStream: HTTP2StreamID(uncheckedRawValue: prioritized),
                                    priorityFieldValue: payload.extracting(droppingFirst: 4))
        default:
            frame = .unknown(type: type, flags: flags, stream: stream, payload: payload)
        }
        return frame
    }

    /// A payload without its padding (§6.1): the pad length byte first, then content, then that many padding bytes.
    @inlinable
    @_lifetime(copy payload)
    static func unpadded(_ payload: RawSpan, _ flags: HTTP2FrameFlags) throws(HTTP2Error) -> RawSpan {
        guard flags.contains(.padded) else { return payload }
        guard payload.byteCount >= 1 else { throw .connection(.frameSizeError) }
        let padding = Int(payload.load(fromByteOffset: 0, as: UInt8.self))
        // Padding that fills or passes the payload is a connection error (§6.1, §6.2).
        guard padding < payload.byteCount else { throw .connection(.protocolError) }
        return payload.extracting(1..<payload.byteCount &- padding)
    }

    /// A priority's 5 bytes: E, the 31-bit dependency, the weight minus 1. A stream can't depend on itself (§5.3.1 of
    /// RFC 7540: a stream error).
    @inlinable
    static func priority(_ bytes: RawSpan, of stream: HTTP2StreamID) throws(HTTP2Error) -> HTTP2Priority {
        let word = UInt32(bigEndian: bytes.load(fromByteOffset: 0, as: UInt32.self))
        let dependency = word & 0x7FFF_FFFF
        guard dependency != stream.rawValue else { throw .stream(stream, .protocolError) }
        return HTTP2Priority(exclusive: word & 0x8000_0000 != 0, dependency: HTTP2StreamID(uncheckedRawValue: dependency),
                             weight: Int(bytes.load(fromByteOffset: 4, as: UInt8.self)) &+ 1)
    }
}

/// HTTP/2 frames to bytes: each function writes one frame, header and payload, in network byte order.
public enum HTTP2FrameWriter {
    /// A frame header: the payload's length, type, flags, and stream.
    @inlinable
    public static func writeHeader(length: Int, type: HTTP2FrameType, flags: HTTP2FrameFlags, stream: HTTP2StreamID,
                                   to writer: inout BigEndianBytesWriter) throws(BytesError) {
        precondition(length >= 0 && length <= 0xFF_FFFF, "a frame payload's length has 24 bits")
        try writer.write(UInt32(truncatingIfNeeded: length), as: Byte3.self)
        try writer.write(type.rawValue)
        try writer.write(flags.rawValue)
        try writer.write(stream.rawValue)
    }

    /// DATA, unpadded.
    @inlinable
    public static func writeData(_ payload: RawSpan, stream: HTTP2StreamID, endStream: Bool,
                                 to writer: inout BigEndianBytesWriter) throws(BytesError) {
        try writeHeader(length: payload.byteCount, type: .data, flags: endStream ? .endStream : [], stream: stream, to: &writer)
        try writer.write(payload)
    }

    /// HEADERS carrying a field block fragment, unpadded and without priority.
    @inlinable
    public static func writeHeaders(_ fieldBlock: RawSpan, stream: HTTP2StreamID, endStream: Bool, endHeaders: Bool,
                                    to writer: inout BigEndianBytesWriter) throws(BytesError) {
        var flags: HTTP2FrameFlags = []
        if endStream { flags.insert(.endStream) }
        if endHeaders { flags.insert(.endHeaders) }
        try writeHeader(length: fieldBlock.byteCount, type: .headers, flags: flags, stream: stream, to: &writer)
        try writer.write(fieldBlock)
    }

    /// CONTINUATION.
    @inlinable
    public static func writeContinuation(_ fieldBlock: RawSpan, stream: HTTP2StreamID, endHeaders: Bool,
                                         to writer: inout BigEndianBytesWriter) throws(BytesError) {
        try writeHeader(length: fieldBlock.byteCount, type: .continuation, flags: endHeaders ? .endHeaders : [], stream: stream, to: &writer)
        try writer.write(fieldBlock)
    }

    /// SETTINGS with the given entries (an empty array for none).
    @inlinable
    public static func writeSettings(_ settings: [(HTTP2SettingID, UInt32)], to writer: inout BigEndianBytesWriter) throws(BytesError) {
        try writeHeader(length: settings.count &* 6, type: .settings, flags: [], stream: .connection, to: &writer)
        for (id, value) in settings {
            try writer.write(id.rawValue)
            try writer.write(value)
        }
    }

    /// A SETTINGS acknowledgment.
    @inlinable
    public static func writeSettingsAcknowledgment(to writer: inout BigEndianBytesWriter) throws(BytesError) {
        try writeHeader(length: 0, type: .settings, flags: .ack, stream: .connection, to: &writer)
    }

    /// PING (or its acknowledgment, which echoes the data).
    @inlinable
    public static func writePing(_ opaqueData: UInt64, ack: Bool, to writer: inout BigEndianBytesWriter) throws(BytesError) {
        try writeHeader(length: 8, type: .ping, flags: ack ? .ack : [], stream: .connection, to: &writer)
        try writer.write(opaqueData)
    }

    /// GOAWAY.
    @inlinable
    public static func writeGoaway(lastStream: HTTP2StreamID, _ code: HTTP2ErrorCode, debugData: RawSpan,
                                   to writer: inout BigEndianBytesWriter) throws(BytesError) {
        try writeHeader(length: 8 &+ debugData.byteCount, type: .goaway, flags: [], stream: .connection, to: &writer)
        try writer.write(lastStream.rawValue)
        try writer.write(code.rawValue)
        try writer.write(debugData)
    }

    /// RST_STREAM.
    @inlinable
    public static func writeResetStream(_ stream: HTTP2StreamID, _ code: HTTP2ErrorCode, to writer: inout BigEndianBytesWriter) throws(BytesError) {
        try writeHeader(length: 4, type: .rstStream, flags: [], stream: stream, to: &writer)
        try writer.write(code.rawValue)
    }

    /// WINDOW_UPDATE.
    @inlinable
    public static func writeWindowUpdate(_ increment: UInt32, stream: HTTP2StreamID, to writer: inout BigEndianBytesWriter) throws(BytesError) {
        precondition(increment > 0 && increment <= 0x7FFF_FFFF, "a window increment is 1 through 2³¹ − 1")
        try writeHeader(length: 4, type: .windowUpdate, flags: [], stream: stream, to: &writer)
        try writer.write(increment)
    }

    /// PRIORITY_UPDATE (RFC 9218): a `Priority` field value for a stream.
    @inlinable
    public static func writePriorityUpdate(_ priorityFieldValue: RawSpan, for stream: HTTP2StreamID,
                                           to writer: inout BigEndianBytesWriter) throws(BytesError) {
        try writeHeader(length: 4 &+ priorityFieldValue.byteCount, type: .priorityUpdate, flags: [], stream: .connection, to: &writer)
        try writer.write(stream.rawValue)
        try writer.write(priorityFieldValue)
    }
}
