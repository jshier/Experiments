import BinaryParsing
import Bytes
import BytesMacros

// A stream of MQTT 5 PUBLISH packets: our kind of parser (the MQTT package's, cut down to one packet type and
// self-contained here), written for each library in its own style. Each packet is
//
// - a fixed-header byte: the packet type (3), then the DUP flag, the QoS (0–2), and the RETAIN flag;
// - the remaining length, a variable-byte integer (7 bits a byte, low groups first, at most 4 bytes);
// - the topic, UTF-8 with a 16-bit big-endian length;
// - a 16-bit packet identifier, for QoS 1 and 2;
// - the properties, a list with a variable-byte-integer length: an identifier, then a byte, a 2- or 4-byte
//   integer, a variable-byte integer, a string, a string pair, or binary data, by identifier;
// - the payload: the rest of the packet.
//
// Both parsers validate the topic and string properties as UTF-8 (without MQTT's U+0000 check, which
// `ParserSpan` has no counterpart for), and sum the fields they read, so nothing is optimized away and nothing
// allocates.

/// MQTT's packet type, the fixed header's high 4 bits: PUBLISH only, here.
enum MQTTPacketType: UInt8 {
    case publish = 3
}

/// A PUBLISH packet's quality of service.
enum MQTTQualityOfService: UInt8 {
    case atMostOnce = 0
    case atLeastOnce = 1
    case exactlyOnce = 2
}

/// A PUBLISH packet's fixed-header byte, by name.
@BitFields(Byte.self)
struct MQTTPublishFlags {
    @Field(bits: 4...7) var type: MQTTPacketType
    @Flag(bit: 3) var duplicate: Bool
    @Field(bits: 1...2) var qualityOfService: MQTTQualityOfService
    @Flag(bit: 0) var retain: Bool
}

/// A packet the `ParserSpan` parser rejects: not a PUBLISH, QoS 3, an unknown property, or a variable-byte integer
/// over 4 bytes. (The Bytes parser throws `BytesError.invalidValue` for these.)
public struct MQTTPublishError: Error {}

public enum MQTTPublish {
    // MARK: Bytes

    /// Parses a stream of PUBLISH packets with `Bytes`.
    ///
    /// - Parameter data: The packets, back to back.
    /// - Returns: The sum of the fields read, so nothing is optimized away.
    /// - Throws: `BytesError.invalidValue` for a packet that isn't a PUBLISH, QoS 3, an unknown property, a
    ///   variable-byte integer over 4 bytes, or invalid UTF-8; `BytesError.insufficientData` for a packet or a
    ///   field cut short.
    public static func parseWithBytes(_ data: RawSpan) throws(BytesError) -> UInt64 {
        var reader = BigEndianBytesReader(data)
        var fields = Fields()
        while !reader.isAtEnd {
            let flags = try reader.read(MQTTPublishFlags.self)
            fields.add(flags.qualityOfService.rawValue)
            fields.add(flags.duplicate ? 1 : 0 as UInt8)
            fields.add(flags.retain ? 1 : 0 as UInt8)
            var packet = try reader.read(sectionPrefixedBy: LEB128.self, maxByteCount: 4)
            fields.add(try packet.read(utf8PrefixedBy: Byte2.self).count) // The topic.
            if flags.qualityOfService != .atMostOnce {
                fields.add(try packet.read(UInt16.self)) // The packet identifier.
            }
            var properties = try packet.read(sectionPrefixedBy: LEB128.self, maxByteCount: 4)
            while !properties.isAtEnd {
                switch try properties.read(LEB128.self, maxByteCount: 4) {
                case 0x01: fields.add(try properties.read(UInt8.self)) // Payload format indicator.
                case 0x02: fields.add(try properties.read(UInt32.self)) // Message expiry interval.
                case 0x23: fields.add(try properties.read(UInt16.self)) // Topic alias.
                case 0x03, 0x08: fields.add(try properties.read(utf8PrefixedBy: Byte2.self).count) // Content type, response topic.
                case 0x09: fields.add(try properties.read(bytesPrefixedBy: Byte2.self).byteCount) // Correlation data.
                case 0x0B: fields.add(try properties.read(LEB128.self, maxByteCount: 4)) // Subscription identifier.
                case 0x26: // User property: a name and a value.
                    fields.add(try properties.read(utf8PrefixedBy: Byte2.self).count)
                    fields.add(try properties.read(utf8PrefixedBy: Byte2.self).count)
                default: throw .invalidValue
                }
            }
            fields.add(packet.remainingByteCount) // The payload.
        }
        return fields.checksum
    }

    // MARK: ParserSpan

    /// Parses a stream of PUBLISH packets with `ParserSpan`.
    ///
    /// - Parameter data: The packets, back to back.
    /// - Returns: The sum of the fields read, as ``parseWithBytes(_:)``.
    /// - Throws: ``MQTTPublishError`` as `BytesError.invalidValue` for ``parseWithBytes(_:)``, except for invalid
    ///   UTF-8; `ParsingError` for a packet or a field cut short, or invalid UTF-8.
    public static func parseWithParserSpan(_ data: RawSpan) throws -> UInt64 {
        var input = ParserSpan(data)
        var fields = Fields()
        while !input.isEmpty {
            let flags = try UInt8(parsing: &input)
            let qualityOfService = flags >> 1 & 3
            guard flags >> 4 == 3, qualityOfService != 3 else { throw MQTTPublishError() }
            fields.add(qualityOfService)
            fields.add(flags >> 3 & 1)
            fields.add(flags & 1)
            var packet = try input.sliceSpan(byteCount: parseVariableByteInteger(&input))
            fields.add(try utf8(&packet).count) // The topic.
            if qualityOfService != 0 {
                fields.add(try UInt16(parsingBigEndian: &packet)) // The packet identifier.
            }
            var properties = try packet.sliceSpan(byteCount: parseVariableByteInteger(&packet))
            while !properties.isEmpty {
                switch try parseVariableByteInteger(&properties) {
                case 0x01: fields.add(try UInt8(parsing: &properties))
                case 0x02: fields.add(try UInt32(parsingBigEndian: &properties))
                case 0x23: fields.add(try UInt16(parsingBigEndian: &properties))
                case 0x03, 0x08: fields.add(try utf8(&properties).count)
                case 0x09:
                    let length = try Int(parsing: &properties, storedAsBigEndian: UInt16.self)
                    fields.add(try properties.sliceSpan(byteCount: length).count)
                case 0x0B: fields.add(try parseVariableByteInteger(&properties))
                case 0x26:
                    fields.add(try utf8(&properties).count)
                    fields.add(try utf8(&properties).count)
                default: throw MQTTPublishError()
                }
            }
            fields.add(packet.count) // The payload.
        }
        return fields.checksum
    }

    /// A variable-byte integer: 7 bits a byte, low groups first, at most 4 bytes.
    @inline(__always)
    static func parseVariableByteInteger(_ input: inout ParserSpan) throws -> Int {
        var value = 0
        for shift in stride(from: 0, to: 28, by: 7) {
            let byte = try UInt8(parsing: &input)
            value |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
        }
        throw MQTTPublishError()
    }

    /// UTF-8 with a 16-bit big-endian length, validated.
    @inline(__always)
    @_lifetime(copy input)
    static func utf8(_ input: inout ParserSpan) throws -> UTF8Span {
        let length = try Int(parsing: &input, storedAsBigEndian: UInt16.self)
        return try input.sliceUTF8Span(byteCount: length)
    }
}

// MARK: - Synthetic streams

/// A synthetic stream of PUBLISH packets for the benchmarks: QoS 0, 1, and 2 in turn, topics of 45–70 bytes (a
/// tenth with a non-ASCII character), zero to eight properties each, and payloads of 0 to 299 bytes.
///
/// - Parameter packetCount: The number of packets.
/// - Returns: The stream's bytes.
public func makeMQTTPublishStream(packetCount: Int) -> [UInt8] {
    func variableByteInteger(_ value: Int) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            let low = UInt8(value & 0x7F)
            value >>= 7
            bytes.append(value > 0 ? low | 0x80 : low)
        } while value > 0
        return bytes
    }
    func twoBytes(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
    func string(_ text: String) -> [UInt8] { twoBytes(text.utf8.count) + Array(text.utf8) }

    var stream: [UInt8] = []
    var state: UInt32 = 0x9E37_79B9
    for index in 0..<packetCount {
        let qualityOfService = index % 3
        let unit = index.isMultiple(of: 10) ? "°C" : "celsius"
        var body = string("sensors/building-\(index % 7)/floor-\(index % 13)/room-\(index % 29)/temperature/\(unit)")
        if qualityOfService > 0 { body += twoBytes(index & 0xFFFF) }
        var properties: [UInt8] = []
        if index.isMultiple(of: 2) { properties += [0x01, 1] }
        if index.isMultiple(of: 3) { properties += [0x02, 0, 0, 0x0E, 0x10] }
        if index.isMultiple(of: 4) { properties += [0x23] + twoBytes(index % 100 + 1) }
        if index.isMultiple(of: 5) { properties += [0x03] + string("application/json") }
        if index.isMultiple(of: 6) { properties += [0x08] + string("replies/\(index)") }
        if index.isMultiple(of: 7) { properties += [0x09] + twoBytes(16) + (0..<16).map { UInt8(truncatingIfNeeded: index &+ $0) } }
        if index.isMultiple(of: 8) { properties += [0x26] + string("source") + string("unit-\(index % 50)") }
        if index.isMultiple(of: 9) { properties += [0x0B] + variableByteInteger(index % 20_000 + 1) }
        body += variableByteInteger(properties.count) + properties
        for _ in 0..<(index &* 37 % 300) {
            state = state &* 1_664_525 &+ 1_013_904_223
            body.append(UInt8(truncatingIfNeeded: state >> 24))
        }
        let duplicate: UInt8 = qualityOfService > 0 && index.isMultiple(of: 11) ? 0x08 : 0
        let retain: UInt8 = index.isMultiple(of: 13) ? 0x01 : 0
        stream.append(0x30 | duplicate | UInt8(qualityOfService) << 1 | retain)
        stream += variableByteInteger(body.count) + body
    }
    return stream
}
