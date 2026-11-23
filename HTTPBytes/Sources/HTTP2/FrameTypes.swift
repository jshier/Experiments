/// A stream identifier (RFC 9113 §5.1.1): 31 bits; 0 is the connection itself.
@frozen
public struct HTTP2StreamID: Sendable, Hashable, Comparable, CustomStringConvertible {
    /// The identifier, 0 through 2³¹ − 1.
    public let rawValue: UInt32

    /// The identifier `rawValue`, which must fit in 31 bits.
    @inlinable
    public init(_ rawValue: UInt32) {
        precondition(rawValue <= 0x7FFF_FFFF, "a stream identifier has 31 bits")
        self.rawValue = rawValue
    }

    @inlinable @inline(__always)
    init(uncheckedRawValue rawValue: UInt32) { self.rawValue = rawValue }

    /// Stream 0: frames about the connection.
    @inlinable public static var connection: Self { Self(uncheckedRawValue: 0) }

    /// Whether this is stream 0.
    @inlinable public var isConnection: Bool { rawValue == 0 }

    /// Whether a client opened it (odd identifiers).
    @inlinable public var isClientInitiated: Bool { rawValue & 1 == 1 }

    @inlinable public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String { "stream \(rawValue)" }
}

/// A frame type (RFC 9113 §6, RFC 9218 §7.1); types this module doesn't know are kept (and ignored, as §5.5 says).
@frozen
public struct HTTP2FrameType: Sendable, Hashable, RawRepresentable {
    public let rawValue: UInt8
    @inlinable public init(rawValue: UInt8) { self.rawValue = rawValue }

    @inlinable public static var data: Self { Self(rawValue: 0x0) }
    @inlinable public static var headers: Self { Self(rawValue: 0x1) }
    @inlinable public static var priority: Self { Self(rawValue: 0x2) }
    @inlinable public static var rstStream: Self { Self(rawValue: 0x3) }
    @inlinable public static var settings: Self { Self(rawValue: 0x4) }
    @inlinable public static var pushPromise: Self { Self(rawValue: 0x5) }
    @inlinable public static var ping: Self { Self(rawValue: 0x6) }
    @inlinable public static var goaway: Self { Self(rawValue: 0x7) }
    @inlinable public static var windowUpdate: Self { Self(rawValue: 0x8) }
    @inlinable public static var continuation: Self { Self(rawValue: 0x9) }
    /// PRIORITY_UPDATE (RFC 9218 §7.1).
    @inlinable public static var priorityUpdate: Self { Self(rawValue: 0x10) }
}

/// A frame's flags. Their meaning depends on the type; the constants are named for the types that define them.
@frozen
public struct HTTP2FrameFlags: Sendable, Hashable, OptionSet {
    public let rawValue: UInt8
    @inlinable public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// END_STREAM (DATA, HEADERS).
    @inlinable public static var endStream: Self { Self(rawValue: 0x1) }
    /// ACK (SETTINGS, PING).
    @inlinable public static var ack: Self { Self(rawValue: 0x1) }
    /// END_HEADERS (HEADERS, PUSH_PROMISE, CONTINUATION).
    @inlinable public static var endHeaders: Self { Self(rawValue: 0x4) }
    /// PADDED (DATA, HEADERS, PUSH_PROMISE).
    @inlinable public static var padded: Self { Self(rawValue: 0x8) }
    /// PRIORITY (HEADERS).
    @inlinable public static var priority: Self { Self(rawValue: 0x20) }
}

/// An error code (RFC 9113 §7), for RST_STREAM and GOAWAY, and for the errors this module throws.
@frozen
public struct HTTP2ErrorCode: Sendable, Hashable, RawRepresentable, CustomStringConvertible {
    public let rawValue: UInt32
    @inlinable public init(rawValue: UInt32) { self.rawValue = rawValue }

    @inlinable public static var noError: Self { Self(rawValue: 0x0) }
    @inlinable public static var protocolError: Self { Self(rawValue: 0x1) }
    @inlinable public static var internalError: Self { Self(rawValue: 0x2) }
    @inlinable public static var flowControlError: Self { Self(rawValue: 0x3) }
    @inlinable public static var settingsTimeout: Self { Self(rawValue: 0x4) }
    @inlinable public static var streamClosed: Self { Self(rawValue: 0x5) }
    @inlinable public static var frameSizeError: Self { Self(rawValue: 0x6) }
    @inlinable public static var refusedStream: Self { Self(rawValue: 0x7) }
    @inlinable public static var cancel: Self { Self(rawValue: 0x8) }
    @inlinable public static var compressionError: Self { Self(rawValue: 0x9) }
    @inlinable public static var connectError: Self { Self(rawValue: 0xA) }
    @inlinable public static var enhanceYourCalm: Self { Self(rawValue: 0xB) }
    @inlinable public static var inadequateSecurity: Self { Self(rawValue: 0xC) }
    @inlinable public static var http11Required: Self { Self(rawValue: 0xD) }

    public var description: String {
        switch rawValue {
        case 0x0: "NO_ERROR"
        case 0x1: "PROTOCOL_ERROR"
        case 0x2: "INTERNAL_ERROR"
        case 0x3: "FLOW_CONTROL_ERROR"
        case 0x4: "SETTINGS_TIMEOUT"
        case 0x5: "STREAM_CLOSED"
        case 0x6: "FRAME_SIZE_ERROR"
        case 0x7: "REFUSED_STREAM"
        case 0x8: "CANCEL"
        case 0x9: "COMPRESSION_ERROR"
        case 0xA: "CONNECT_ERROR"
        case 0xB: "ENHANCE_YOUR_CALM"
        case 0xC: "INADEQUATE_SECURITY"
        case 0xD: "HTTP_1_1_REQUIRED"
        default: "0x\(String(rawValue, radix: 16))"
        }
    }
}

/// An HTTP/2 error (RFC 9113 §5.4): a connection error (the connection ends with GOAWAY) or a stream error (the
/// stream ends with RST_STREAM), with its code. No other payload, so throwing allocates nothing.
@frozen
public enum HTTP2Error: Error, Sendable, Hashable {
    /// End the connection: send GOAWAY with the code.
    case connection(HTTP2ErrorCode)
    /// End the stream: send RST_STREAM with the code.
    case stream(HTTP2StreamID, HTTP2ErrorCode)

    /// The error's code.
    @inlinable
    public var code: HTTP2ErrorCode {
        switch self {
        case .connection(let code), .stream(_, let code): code
        }
    }
}

/// A setting's identifier (RFC 9113 §6.5.2, RFC 8441 §3, RFC 9218 §2.1).
@frozen
public struct HTTP2SettingID: Sendable, Hashable, RawRepresentable {
    public let rawValue: UInt16
    @inlinable public init(rawValue: UInt16) { self.rawValue = rawValue }

    @inlinable public static var headerTableSize: Self { Self(rawValue: 0x1) }
    @inlinable public static var enablePush: Self { Self(rawValue: 0x2) }
    @inlinable public static var maxConcurrentStreams: Self { Self(rawValue: 0x3) }
    @inlinable public static var initialWindowSize: Self { Self(rawValue: 0x4) }
    @inlinable public static var maxFrameSize: Self { Self(rawValue: 0x5) }
    @inlinable public static var maxHeaderListSize: Self { Self(rawValue: 0x6) }
    /// SETTINGS_ENABLE_CONNECT_PROTOCOL (RFC 8441): extended CONNECT.
    @inlinable public static var enableConnectProtocol: Self { Self(rawValue: 0x8) }
    /// SETTINGS_NO_RFC7540_PRIORITIES (RFC 9218).
    @inlinable public static var noRFC7540Priorities: Self { Self(rawValue: 0x9) }
}

/// The settings an endpoint has sent, with RFC 9113's initial values.
@frozen
public struct HTTP2Settings: Sendable, Hashable {
    /// SETTINGS_HEADER_TABLE_SIZE: the HPACK dynamic table's limit the sender's decoder allows.
    public var headerTableSize: UInt32 = 4_096
    /// SETTINGS_ENABLE_PUSH.
    public var enablePush = true
    /// SETTINGS_MAX_CONCURRENT_STREAMS (`nil`: unlimited).
    public var maxConcurrentStreams: UInt32?
    /// SETTINGS_INITIAL_WINDOW_SIZE.
    public var initialWindowSize: UInt32 = 65_535
    /// SETTINGS_MAX_FRAME_SIZE.
    public var maxFrameSize: UInt32 = 16_384
    /// SETTINGS_MAX_HEADER_LIST_SIZE (`nil`: unlimited), counted as RFC 7541 §4.1 says: name + value + 32 per field.
    public var maxHeaderListSize: UInt32?
    /// SETTINGS_ENABLE_CONNECT_PROTOCOL.
    public var enableConnectProtocol = false
    /// SETTINGS_NO_RFC7540_PRIORITIES.
    public var noRFC7540Priorities = false

    @inlinable
    public init() {}

    /// Applies one setting, checking its value's range (RFC 9113 §6.5.2); unknown settings are ignored (§6.5.2: "MUST
    /// ignore").
    @inlinable
    public mutating func apply(_ id: HTTP2SettingID, _ value: UInt32) throws(HTTP2Error) {
        switch id {
        case .headerTableSize: headerTableSize = value
        case .enablePush:
            guard value <= 1 else { throw .connection(.protocolError) }
            enablePush = value == 1
        case .maxConcurrentStreams: maxConcurrentStreams = value
        case .initialWindowSize:
            guard value <= 0x7FFF_FFFF else { throw .connection(.flowControlError) }
            initialWindowSize = value
        case .maxFrameSize:
            guard value >= 16_384, value <= 0xFF_FFFF else { throw .connection(.protocolError) }
            maxFrameSize = value
        case .maxHeaderListSize: maxHeaderListSize = value
        case .enableConnectProtocol:
            guard value <= 1 else { throw .connection(.protocolError) }
            enableConnectProtocol = value == 1
        case .noRFC7540Priorities:
            guard value <= 1 else { throw .connection(.protocolError) }
            noRFC7540Priorities = value == 1
        default: break
        }
    }
}

/// RFC 7540's stream priority, carried by PRIORITY frames and HEADERS with the PRIORITY flag. RFC 9113 deprecates the
/// scheme; frames carrying it are still parsed (and their fields checked), and a receiver may ignore it.
@frozen
public struct HTTP2Priority: Sendable, Hashable {
    /// Whether the dependency is exclusive.
    public let exclusive: Bool
    /// The stream depended on.
    public let dependency: HTTP2StreamID
    /// The weight, 1–256.
    public let weight: Int

    @inlinable
    public init(exclusive: Bool, dependency: HTTP2StreamID, weight: Int) {
        self.exclusive = exclusive
        self.dependency = dependency
        self.weight = weight
    }
}
