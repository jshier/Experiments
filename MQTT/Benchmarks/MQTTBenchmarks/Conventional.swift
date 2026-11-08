// A conventional MQTT 5 PUBLISH parser and encoder, the way they're usually written in Swift: index
// arithmetic over `[UInt8]`, owned `String`s and arrays, an array of decoded properties. The comparison for
// the `Bytes`-based views. It validates the same things (lengths, UTF-8, QoS, identifiers).

enum ConventionalError: Error { case incomplete, malformed }

enum ConventionalProperty {
    case messageExpiryInterval(UInt32)
    case userProperty(String, String)
    case contentType(String)
    case topicAlias(UInt16)
}

struct ConventionalPublish {
    var duplicate: Bool
    var qos: UInt8
    var retain: Bool
    var topic: String
    var packetIdentifier: UInt16?
    var properties: [ConventionalProperty]
    var payload: [UInt8]
}

enum Conventional {
    static func readVariableByteInteger(_ data: [UInt8], _ index: inout Int, end: Int) throws -> Int {
        var value = 0
        var shift = 0
        while true {
            guard index < end else { throw ConventionalError.incomplete }
            guard shift < 28 else { throw ConventionalError.malformed }
            let byte = data[index]
            index += 1
            value |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
    }

    static func readUInt16(_ data: [UInt8], _ index: inout Int, end: Int) throws -> UInt16 {
        guard index + 2 <= end else { throw ConventionalError.malformed }
        defer { index += 2 }
        return UInt16(data[index]) << 8 | UInt16(data[index + 1])
    }

    static func readUInt32(_ data: [UInt8], _ index: inout Int, end: Int) throws -> UInt32 {
        guard index + 4 <= end else { throw ConventionalError.malformed }
        defer { index += 4 }
        return UInt32(data[index]) << 24 | UInt32(data[index + 1]) << 16 | UInt32(data[index + 2]) << 8 | UInt32(data[index + 3])
    }

    static func readString(_ data: [UInt8], _ index: inout Int, end: Int) throws -> String {
        let length = try Int(readUInt16(data, &index, end: end))
        guard index + length <= end, let string = String(validating: data[index..<index + length], as: UTF8.self) else {
            throw ConventionalError.malformed
        }
        index += length
        return string
    }

    /// Parses every PUBLISH in `range` of `data`.
    static func parsePublishes(_ data: [UInt8], in range: Range<Int>, _ handle: (ConventionalPublish) -> Void) throws {
        var index = range.lowerBound
        while index < range.upperBound {
            let first = data[index]
            index += 1
            let length = try readVariableByteInteger(data, &index, end: range.upperBound)
            let end = index + length
            guard end <= range.upperBound else { throw ConventionalError.incomplete }
            guard first >> 4 == 3 else { throw ConventionalError.malformed }
            let qos = first >> 1 & 0b11
            guard qos < 3 else { throw ConventionalError.malformed }
            let topic = try readString(data, &index, end: end)
            var packetIdentifier: UInt16?
            if qos > 0 {
                packetIdentifier = try readUInt16(data, &index, end: end)
                guard packetIdentifier != 0 else { throw ConventionalError.malformed }
            }
            let propertiesLength = try readVariableByteInteger(data, &index, end: end)
            let propertiesEnd = index + propertiesLength
            guard propertiesEnd <= end else { throw ConventionalError.malformed }
            var properties: [ConventionalProperty] = []
            while index < propertiesEnd {
                let identifier = try readVariableByteInteger(data, &index, end: propertiesEnd)
                switch identifier {
                case 0x02: try properties.append(.messageExpiryInterval(readUInt32(data, &index, end: propertiesEnd)))
                case 0x03: try properties.append(.contentType(readString(data, &index, end: propertiesEnd)))
                case 0x23: try properties.append(.topicAlias(readUInt16(data, &index, end: propertiesEnd)))
                case 0x26:
                    let name = try readString(data, &index, end: propertiesEnd)
                    try properties.append(.userProperty(name, readString(data, &index, end: propertiesEnd)))
                default: throw ConventionalError.malformed
                }
            }
            handle(ConventionalPublish(
                duplicate: first & 0b1000 != 0, qos: qos, retain: first & 1 != 0, topic: topic,
                packetIdentifier: packetIdentifier, properties: properties, payload: Array(data[index..<end])
            ))
            index = end
        }
    }

    /// Appends an encoded PUBLISH to `output`.
    static func appendPublish(_ publish: ConventionalPublish, to output: inout [UInt8]) {
        var properties: [UInt8] = []
        for property in publish.properties {
            switch property {
            case let .messageExpiryInterval(value):
                properties.append(0x02)
                properties += [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
            case let .userProperty(name, value):
                properties.append(0x26)
                appendString(name, to: &properties)
                appendString(value, to: &properties)
            case let .contentType(value):
                properties.append(0x03)
                appendString(value, to: &properties)
            case let .topicAlias(value):
                properties.append(0x23)
                properties += [UInt8(value >> 8), UInt8(truncatingIfNeeded: value)]
            }
        }
        var propertyLength: [UInt8] = []
        appendVariableByteInteger(properties.count, to: &propertyLength)
        let remaining = 2 + publish.topic.utf8.count + (publish.packetIdentifier == nil ? 0 : 2)
            + propertyLength.count + properties.count + publish.payload.count
        output.append(0x30 | (publish.duplicate ? 0b1000 : 0) | publish.qos << 1 | (publish.retain ? 1 : 0))
        appendVariableByteInteger(remaining, to: &output)
        appendString(publish.topic, to: &output)
        if let identifier = publish.packetIdentifier { output += [UInt8(identifier >> 8), UInt8(truncatingIfNeeded: identifier)] }
        output += propertyLength
        output += properties
        output += publish.payload
    }

    static func appendString(_ string: String, to output: inout [UInt8]) {
        let count = string.utf8.count
        output += [UInt8(count >> 8), UInt8(truncatingIfNeeded: count)]
        output += string.utf8
    }

    static func appendVariableByteInteger(_ value: Int, to output: inout [UInt8]) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining > 0 { byte |= 0x80 }
            output.append(byte)
        } while remaining > 0
    }
}
