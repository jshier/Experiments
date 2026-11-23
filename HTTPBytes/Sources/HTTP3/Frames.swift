public import Bytes

/// An HTTP/3 error code (RFC 9114 §8.1, RFC 9204 §6), for stream resets, CONNECTION_CLOSE, and the errors thrown here.
@frozen
public struct HTTP3ErrorCode: Sendable, Hashable, RawRepresentable, CustomStringConvertible {
    public let rawValue: UInt64
    @inlinable public init(rawValue: UInt64) { self.rawValue = rawValue }

    @inlinable public static var noError: Self { Self(rawValue: 0x100) }
    @inlinable public static var generalProtocolError: Self { Self(rawValue: 0x101) }
    @inlinable public static var internalError: Self { Self(rawValue: 0x102) }
    @inlinable public static var streamCreationError: Self { Self(rawValue: 0x103) }
    @inlinable public static var closedCriticalStream: Self { Self(rawValue: 0x104) }
    @inlinable public static var frameUnexpected: Self { Self(rawValue: 0x105) }
    @inlinable public static var frameError: Self { Self(rawValue: 0x106) }
    @inlinable public static var excessiveLoad: Self { Self(rawValue: 0x107) }
    @inlinable public static var idError: Self { Self(rawValue: 0x108) }
    @inlinable public static var settingsError: Self { Self(rawValue: 0x109) }
    @inlinable public static var missingSettings: Self { Self(rawValue: 0x10A) }
    @inlinable public static var requestRejected: Self { Self(rawValue: 0x10B) }
    @inlinable public static var requestCancelled: Self { Self(rawValue: 0x10C) }
    @inlinable public static var requestIncomplete: Self { Self(rawValue: 0x10D) }
    @inlinable public static var messageError: Self { Self(rawValue: 0x10E) }
    @inlinable public static var connectError: Self { Self(rawValue: 0x10F) }
    @inlinable public static var versionFallback: Self { Self(rawValue: 0x110) }
    /// QPACK_DECOMPRESSION_FAILED.
    @inlinable public static var qpackDecompressionFailed: Self { Self(rawValue: 0x200) }
    /// QPACK_ENCODER_STREAM_ERROR.
    @inlinable public static var qpackEncoderStreamError: Self { Self(rawValue: 0x201) }
    /// QPACK_DECODER_STREAM_ERROR.
    @inlinable public static var qpackDecoderStreamError: Self { Self(rawValue: 0x202) }

    public var description: String { "0x\(String(rawValue, radix: 16))" }
}

/// An HTTP/3 error: the connection closes with the code (every error this module finds is a connection error, as RFC
/// 9114 §7.1 says of malformed frames, except where a stream error is named).
@frozen
public enum HTTP3Error: Error, Sendable, Hashable {
    /// Close the connection with the code.
    case connection(HTTP3ErrorCode)
    /// Reset the stream with the code (H3_MESSAGE_ERROR for a malformed message).
    case stream(HTTP3ErrorCode)
}

/// A frame type (RFC 9114 §7.2, RFC 9218 §7.2).
@frozen
public struct HTTP3FrameType: Sendable, Hashable, RawRepresentable {
    public let rawValue: UInt64
    @inlinable public init(rawValue: UInt64) { self.rawValue = rawValue }

    @inlinable public static var data: Self { Self(rawValue: 0x0) }
    @inlinable public static var headers: Self { Self(rawValue: 0x1) }
    @inlinable public static var cancelPush: Self { Self(rawValue: 0x3) }
    @inlinable public static var settings: Self { Self(rawValue: 0x4) }
    @inlinable public static var pushPromise: Self { Self(rawValue: 0x5) }
    @inlinable public static var goaway: Self { Self(rawValue: 0x7) }
    @inlinable public static var maxPushID: Self { Self(rawValue: 0xD) }
    /// PRIORITY_UPDATE for a request stream (RFC 9218).
    @inlinable public static var priorityUpdateRequest: Self { Self(rawValue: 0xF0700) }
    /// PRIORITY_UPDATE for a push stream.
    @inlinable public static var priorityUpdatePush: Self { Self(rawValue: 0xF0701) }

    /// HTTP/2's frame types that HTTP/3 reserves and forbids (§7.2.8): PRIORITY, PING, WINDOW_UPDATE, CONTINUATION.
    @inlinable public var isHTTP2Only: Bool { rawValue == 0x2 || rawValue == 0x6 || rawValue == 0x8 || rawValue == 0x9 }
}

/// A setting's identifier (RFC 9114 §7.2.4.1, RFC 9204 §5, RFC 9220 §3, RFC 9297 §2.1.1).
@frozen
public struct HTTP3SettingID: Sendable, Hashable, RawRepresentable {
    public let rawValue: UInt64
    @inlinable public init(rawValue: UInt64) { self.rawValue = rawValue }

    /// SETTINGS_QPACK_MAX_TABLE_CAPACITY.
    @inlinable public static var qpackMaxTableCapacity: Self { Self(rawValue: 0x1) }
    /// SETTINGS_MAX_FIELD_SECTION_SIZE.
    @inlinable public static var maxFieldSectionSize: Self { Self(rawValue: 0x6) }
    /// SETTINGS_QPACK_BLOCKED_STREAMS.
    @inlinable public static var qpackBlockedStreams: Self { Self(rawValue: 0x7) }
    /// SETTINGS_ENABLE_CONNECT_PROTOCOL (extended CONNECT).
    @inlinable public static var enableConnectProtocol: Self { Self(rawValue: 0x8) }
    /// SETTINGS_H3_DATAGRAM.
    @inlinable public static var h3Datagram: Self { Self(rawValue: 0x33) }
}

/// The settings a peer sent, with RFC 9114's and RFC 9204's defaults.
@frozen
public struct HTTP3Settings: Sendable, Hashable {
    /// SETTINGS_QPACK_MAX_TABLE_CAPACITY (default 0: no dynamic table).
    public var qpackMaxTableCapacity: UInt64 = 0
    /// SETTINGS_QPACK_BLOCKED_STREAMS (default 0).
    public var qpackBlockedStreams: UInt64 = 0
    /// SETTINGS_MAX_FIELD_SECTION_SIZE (`nil`: unlimited).
    public var maxFieldSectionSize: UInt64?
    /// SETTINGS_ENABLE_CONNECT_PROTOCOL.
    public var enableConnectProtocol = false
    /// SETTINGS_H3_DATAGRAM.
    public var h3Datagram = false

    @inlinable
    public init() {}
}

/// A SETTINGS frame's payload: (identifier, value) pairs of variable-length integers.
@frozen
public struct HTTP3SettingsPayload: ~Escapable {
    /// The pairs' bytes.
    public let bytes: RawSpan

    @inlinable @inline(__always)
    @_lifetime(copy bytes)
    init(bytes: RawSpan) { self.bytes = bytes }

    /// Calls `body` with each setting, in order; throws H3_FRAME_ERROR if a pair is cut short.
    @inlinable
    public func forEach(_ body: (HTTP3SettingID, UInt64) throws(HTTP3Error) -> Void) throws(HTTP3Error) {
        var offset = 0
        while offset < bytes.byteCount {
            guard let (id, idLength) = QUICVariableLengthInteger.read(bytes, at: offset),
                  let (value, valueLength) = QUICVariableLengthInteger.read(bytes, at: offset &+ idLength) else {
                throw .connection(.frameError)
            }
            try body(HTTP3SettingID(rawValue: id), value)
            offset &+= idLength &+ valueLength
        }
    }

    /// Applies the settings (RFC 9114 §7.2.4): a repeated identifier, or one of HTTP/2's (0x2–0x5), is
    /// H3_SETTINGS_ERROR; unknown identifiers (reserved ones included) are ignored; ENABLE_CONNECT_PROTOCOL and
    /// H3_DATAGRAM must be 0 or 1.
    @inlinable
    public func apply(to settings: inout HTTP3Settings) throws(HTTP3Error) {
        var seen: InlineArray<8, UInt64> = .init(repeating: .max)
        var seenCount = 0
        var updated = settings
        try forEach { (id, value) throws(HTTP3Error) in
            guard id.rawValue < 2 || id.rawValue > 5 else { throw .connection(.settingsError) }
            switch id {
            case .qpackMaxTableCapacity, .maxFieldSectionSize, .qpackBlockedStreams, .enableConnectProtocol, .h3Datagram:
                for index in 0..<seenCount where seen[index] == id.rawValue { throw .connection(.settingsError) }
                seen[seenCount] = id.rawValue
                seenCount &+= 1
            default:
                return
            }
            switch id {
            case .qpackMaxTableCapacity: updated.qpackMaxTableCapacity = value
            case .maxFieldSectionSize: updated.maxFieldSectionSize = value
            case .qpackBlockedStreams: updated.qpackBlockedStreams = value
            case .enableConnectProtocol:
                guard value <= 1 else { throw .connection(.settingsError) }
                updated.enableConnectProtocol = value == 1
            default:
                guard value <= 1 else { throw .connection(.settingsError) }
                updated.h3Datagram = value == 1
            }
        }
        settings = updated
    }
}

/// The kind of stream a frame arrived on, which decides which frames may (RFC 9114 §7.2, the table in Appendix A.2).
@frozen
public enum HTTP3StreamKind: Sendable, Hashable {
    /// The control stream: SETTINGS first and once; CANCEL_PUSH, GOAWAY, MAX_PUSH_ID, PRIORITY_UPDATE.
    case control
    /// A request stream: HEADERS, DATA, PUSH_PROMISE (server to client).
    case request
    /// A push stream: HEADERS, DATA.
    case push
}

/// A unidirectional stream's type (RFC 9114 §6.2, RFC 9204 §4.2), its first variable-length integer.
@frozen
public struct HTTP3UnidirectionalStreamType: Sendable, Hashable, RawRepresentable {
    public let rawValue: UInt64
    @inlinable public init(rawValue: UInt64) { self.rawValue = rawValue }

    @inlinable public static var control: Self { Self(rawValue: 0x00) }
    @inlinable public static var push: Self { Self(rawValue: 0x01) }
    @inlinable public static var qpackEncoder: Self { Self(rawValue: 0x02) }
    @inlinable public static var qpackDecoder: Self { Self(rawValue: 0x03) }
}

/// A frame, as parsed: values and views of the payload.
public enum HTTP3Frame: ~Escapable {
    /// DATA.
    case data(RawSpan)
    /// HEADERS: an encoded field section (QPACK).
    case headers(RawSpan)
    /// CANCEL_PUSH.
    case cancelPush(pushID: UInt64)
    /// SETTINGS.
    case settings(HTTP3SettingsPayload)
    /// PUSH_PROMISE: the push ID, then an encoded field section.
    case pushPromise(pushID: UInt64, fieldSection: RawSpan)
    /// GOAWAY: a stream ID (from a server) or push ID (from a client).
    case goaway(UInt64)
    /// MAX_PUSH_ID.
    case maxPushID(UInt64)
    /// PRIORITY_UPDATE: the element (a request stream ID or push ID) and a `Priority` field value.
    case priorityUpdate(push: Bool, elementID: UInt64, priorityFieldValue: RawSpan)
    /// Part of a frame of a type this module doesn't know, reserved ones included (§9: to be ignored, whatever its
    /// size): streamed as DATA is, `remaining` the payload bytes still to come after this part (0 for the last).
    case unknown(type: HTTP3FrameType, payload: RawSpan, remaining: Int)
    /// The bytes end before the frame's type and length do, or (for a frame that isn't streamed) before its payload
    /// does, or no byte of a streamed payload is here yet. Nothing was consumed and nothing changed: call again with the
    /// same bytes and more.
    case needsMore
}

/// The endpoint receiving the frames, which decides some of what may come (RFC 9114 §6.2.2, §7.2.5, §7.2.7; RFC 9218
/// §7.2).
@frozen
public enum HTTP3Role: Sendable, Hashable {
    case client
    case server
}

/// HTTP/3 frames from one stream's bytes (RFC 9114 §7): type and length as variable-length integers, then the payload.
/// Allocates nothing. Checks:
/// - each frame's contents, and whether its type may come on this kind of stream (Appendix A.2), and on the control stream
///   that SETTINGS comes first and only once;
/// - on request and push streams, the message's frame order (§4.1): HEADERS first; DATA only after HEADERS; nothing but
///   PUSH_PROMISE and unknown types after trailers (a HEADERS frame after DATA, or a request's second HEADERS frame when
///   the role is ``HTTP3Role/server``). Every error is H3_FRAME_UNEXPECTED. A response's HEADERS frames before its DATA
///   may be interim (1xx) ones, which only decoding tells apart: call ``finalHeadersReceived()`` after a final
///   response's HEADERS so that a later HEADERS frame counts as trailers;
/// - with a ``role``, the frames only the other role sends: a server receiving PUSH_PROMISE, or a push stream; a client
///   receiving MAX_PUSH_ID or PRIORITY_UPDATE.
///
/// DATA payloads, and unknown frame types' (which §9 says to ignore, whatever their size), are handed out in parts as
/// they arrive, so they can be any size; other frames' payloads are limited by ``maximumFrameSize``.
@frozen
public struct HTTP3FrameParser: Sendable {
    /// The stream's kind.
    public let streamKind: HTTP3StreamKind
    /// The endpoint receiving the frames, if the parser should check what only the other role sends.
    public let role: HTTP3Role?
    /// The largest payload accepted for frames other than DATA and unknown types (H3_EXCESSIVE_LOAD beyond it).
    public var maximumFrameSize: Int
    @usableFromInline var sawSettings = false
    /// Payload bytes of a streamed frame (DATA or an unknown type) still to hand out.
    @usableFromInline var remaining = 0
    /// The streamed frame's type.
    @usableFromInline var streamedType: UInt64 = 0
    /// A request or push stream's message so far: `MessageState`.
    @usableFromInline var message: UInt8 = 0

    /// Where a request or push stream's message is (§4.1).
    @usableFromInline
    enum MessageState {
        /// No HEADERS yet.
        @inlinable static var start: UInt8 { 0 }
        /// HEADERS, perhaps interim (1xx) ones: more HEADERS or DATA may follow.
        @inlinable static var head: UInt8 { 1 }
        /// The final HEADERS (and perhaps DATA): DATA, or HEADERS as trailers, may follow.
        @inlinable static var body: UInt8 { 2 }
        /// Trailers: no more HEADERS or DATA.
        @inlinable static var trailers: UInt8 { 3 }
    }

    @inlinable
    public init(streamKind: HTTP3StreamKind, role: HTTP3Role? = nil, maximumFrameSize: Int = 1 << 20) {
        self.streamKind = streamKind
        self.role = role
        self.maximumFrameSize = maximumFrameSize
    }

    /// Tells the parser that the last HEADERS frame on this request or push stream was a final response's (not 1xx): a
    /// later HEADERS frame is then trailers, after which HEADERS and DATA are H3_FRAME_UNEXPECTED.
    @inlinable
    public mutating func finalHeadersReceived() {
        if message == MessageState.head { message = MessageState.body }
    }

    /// The next frame in `bytes` (the stream's unconsumed bytes), or the next part of a DATA frame's or unknown frame's
    /// payload.
    ///
    /// - Parameter consumed: Set to the bytes used: a frame's size (type, length, payload), a part's size (plus the
    ///   frame's type and length for its first part), or 0 for ``HTTP3Frame/needsMore``, which changes nothing.
    @inlinable
    @_lifetime(copy bytes)
    public mutating func next(in bytes: RawSpan, consumed: inout Int) throws(HTTP3Error) -> HTTP3Frame {
        consumed = 0
        if remaining > 0 {
            let take = Swift.min(remaining, bytes.byteCount)
            guard take > 0 else { return .needsMore }
            remaining &-= take
            consumed = take
            let part = bytes.extracting(0..<take)
            return streamedType == 0 ? .data(part) : .unknown(type: HTTP3FrameType(rawValue: streamedType), payload: part, remaining: remaining)
        }
        guard let (typeValue, typeLength) = QUICVariableLengthInteger.read(bytes, at: 0),
              let (lengthValue, lengthLength) = QUICVariableLengthInteger.read(bytes, at: typeLength) else { return .needsMore }
        let type = HTTP3FrameType(rawValue: typeValue)
        // The type is checked before the payload arrives: a frame that can't be here is an error at once. Its effect on
        // the stream's state waits until the frame is handed out.
        let nextMessage = try check(type)
        let start = typeLength &+ lengthLength
        let available = bytes.byteCount &- start
        if type == .data || !type.isKnown {
            // Streamed: whatever of the payload is here now, the rest on later calls. (A length is below 2⁶².)
            let length = Int(truncatingIfNeeded: lengthValue)
            guard length == 0 || available > 0 else { return .needsMore }
            let take = Swift.min(length, available)
            message = nextMessage
            remaining = length &- take
            streamedType = typeValue
            consumed = start &+ take
            let part = bytes.extracting(start..<start &+ take)
            return type == .data ? .data(part) : .unknown(type: type, payload: part, remaining: remaining)
        }
        guard lengthValue <= UInt64(maximumFrameSize) else { throw .connection(.excessiveLoad) }
        let length = Int(lengthValue)
        guard available >= length else { return .needsMore }
        let payload = bytes.extracting(start..<start &+ length)
        let frame: HTTP3Frame
        switch type {
        case .headers: frame = .headers(payload)
        case .settings:
            sawSettings = true
            frame = .settings(HTTP3SettingsPayload(bytes: payload))
        case .cancelPush, .goaway, .maxPushID:
            // One variable-length integer, exactly filling the payload.
            guard let (value, valueLength) = QUICVariableLengthInteger.read(payload, at: 0), valueLength == length else {
                throw .connection(.frameError)
            }
            frame = type == .cancelPush ? .cancelPush(pushID: value) : type == .goaway ? .goaway(value) : .maxPushID(value)
        case .pushPromise:
            guard let (pushID, idLength) = QUICVariableLengthInteger.read(payload, at: 0) else { throw .connection(.frameError) }
            frame = .pushPromise(pushID: pushID, fieldSection: payload.extracting(droppingFirst: idLength))
        case .priorityUpdateRequest, .priorityUpdatePush:
            guard let (element, elementLength) = QUICVariableLengthInteger.read(payload, at: 0) else { throw .connection(.frameError) }
            frame = .priorityUpdate(push: type == .priorityUpdatePush, elementID: element,
                                    priorityFieldValue: payload.extracting(droppingFirst: elementLength))
        default:
            // Not reached: unknown types are streamed above, HTTP/2's rejected by `check`.
            frame = .unknown(type: type, payload: payload, remaining: 0)
        }
        message = nextMessage
        consumed = start &+ length
        return frame
    }

    /// Whether `type` may come now on this stream (§4.1, §7.2, Appendix A.2): the message state it leads to (unchanged
    /// but on request and push streams).
    @inlinable
    func check(_ type: HTTP3FrameType) throws(HTTP3Error) -> UInt8 {
        if type.isHTTP2Only { throw .connection(.frameUnexpected) }
        switch streamKind {
        case .control:
            if !sawSettings, type != .settings { throw .connection(.missingSettings) }
            switch type {
            case .settings: if sawSettings { throw .connection(.frameUnexpected) }
            case .data, .headers, .pushPromise: throw .connection(.frameUnexpected)
            case .maxPushID, .priorityUpdateRequest, .priorityUpdatePush:
                // Only clients send them (§7.2.7; RFC 9218 §7.2).
                if role == .client { throw .connection(.frameUnexpected) }
            default: break
            }
            return message
        case .request, .push:
            // Only servers push (§6.2.2), on push streams and with PUSH_PROMISE (§7.2.5).
            if role == .server, streamKind == .push { throw .connection(.streamCreationError) }
            switch type {
            case .data:
                guard message == MessageState.head || message == MessageState.body else { throw .connection(.frameUnexpected) }
                return MessageState.body
            case .headers:
                switch message {
                case MessageState.start:
                    // A request has no interim heads: its next HEADERS frame is trailers.
                    return role == .server && streamKind == .request ? MessageState.body : MessageState.head
                case MessageState.head: return MessageState.head
                case MessageState.body: return MessageState.trailers
                default: throw .connection(.frameUnexpected)
                }
            case .cancelPush, .settings, .goaway, .maxPushID, .priorityUpdateRequest, .priorityUpdatePush:
                throw .connection(.frameUnexpected)
            case .pushPromise:
                if streamKind == .push || role == .server { throw .connection(.frameUnexpected) }
                return message
            default:
                return message
            }
        }
    }
}

extension HTTP3FrameType {
    /// Whether the parser knows the type (the frames ``HTTP3Frame`` has cases for, and HTTP/2's, which it rejects).
    @inlinable
    var isKnown: Bool {
        switch rawValue {
        case 0x0...0x9, 0xD, 0xF0700, 0xF0701: true
        default: false
        }
    }
}

/// HTTP/3 frames to bytes.
public enum HTTP3FrameWriter {
    /// A frame's type and length.
    @inlinable
    public static func writeHeader(_ type: HTTP3FrameType, length: Int, to writer: inout BigEndianBytesWriter) throws(BytesError) {
        try QUICVariableLengthInteger.write(type.rawValue, to: &writer)
        try QUICVariableLengthInteger.write(UInt64(length), to: &writer)
    }

    /// A frame of `type` with `payload` (DATA, HEADERS).
    @inlinable
    public static func write(_ type: HTTP3FrameType, payload: RawSpan, to writer: inout BigEndianBytesWriter) throws(BytesError) {
        try writeHeader(type, length: payload.byteCount, to: &writer)
        try writer.write(payload)
    }

    /// SETTINGS with the given pairs.
    @inlinable
    public static func writeSettings(_ settings: [(HTTP3SettingID, UInt64)], to writer: inout BigEndianBytesWriter) throws(BytesError) {
        var length = 0
        for (id, value) in settings {
            length &+= QUICVariableLengthInteger.length(of: id.rawValue) &+ QUICVariableLengthInteger.length(of: value)
        }
        try writeHeader(.settings, length: length, to: &writer)
        for (id, value) in settings {
            try QUICVariableLengthInteger.write(id.rawValue, to: &writer)
            try QUICVariableLengthInteger.write(value, to: &writer)
        }
    }

    /// GOAWAY, CANCEL_PUSH, or MAX_PUSH_ID: one integer.
    @inlinable
    public static func write(_ type: HTTP3FrameType, integer: UInt64, to writer: inout BigEndianBytesWriter) throws(BytesError) {
        try writeHeader(type, length: QUICVariableLengthInteger.length(of: integer), to: &writer)
        try QUICVariableLengthInteger.write(integer, to: &writer)
    }
}
