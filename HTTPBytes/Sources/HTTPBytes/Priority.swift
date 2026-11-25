public import Bytes

/// A response's priority (RFC 9218 §4): its urgency and whether it can be sent incrementally. The value of a
/// `Priority` field, or of an HTTP/2 or HTTP/3 PRIORITY_UPDATE frame's Priority Field Value.
///
/// Both are parameters of a Structured Fields Dictionary: `u`, an Integer from 0 (most urgent) to 7, 3 by default;
/// `i`, a Boolean, `false` by default. Unknown members, and `u` or `i` with a value out of range or of another type,
/// are ignored (the default stands), as RFC 9218 §4 requires; a field that isn't a valid Dictionary throws, and its
/// sender's priority is then the default (RFC 9651 §4.2: the field is ignored).
///
/// ```swift
/// let priority = (try? HTTPPriority(parsing: fieldValue)) ?? .default
/// ```
@frozen
public struct HTTPPriority: Sendable, Hashable, CustomStringConvertible {
    /// The urgency, 0 (most urgent) through 7.
    public var urgency: Int {
        didSet { precondition(urgency >= 0 && urgency <= 7, "an urgency is 0 through 7") }
    }

    /// Whether the response can be processed incrementally, as it arrives (so interleaving it with others helps).
    public var isIncremental: Bool

    /// The default urgency, 3 (RFC 9218 §4.1).
    @inlinable public static var defaultUrgency: Int { 3 }

    /// Urgency 3, not incremental: the priority of a request that states none.
    @inlinable public static var `default`: Self { Self() }

    /// A priority of `urgency` (0 through 7), incremental or not.
    @inlinable
    public init(urgency: Int = HTTPPriority.defaultUrgency, isIncremental: Bool = false) {
        precondition(urgency >= 0 && urgency <= 7, "an urgency is 0 through 7")
        self.urgency = urgency
        self.isIncremental = isIncremental
    }

    /// The priority in a `Priority` field value, or a PRIORITY_UPDATE frame's Priority Field Value.
    ///
    /// - Throws: ``HTTPStructuredFieldError`` if the value isn't a Structured Fields Dictionary.
    @inlinable
    public init(parsing fieldValue: RawSpan) throws(HTTPStructuredFieldError) {
        self.init()
        var dictionary = HTTPStructuredDictionary(fieldValue)
        try update(from: &dictionary)
    }

    /// Applies the rest of `dictionary`'s field line: the last `u` and `i` in it replace this priority's (a member with
    /// a value of the wrong type or out of range resets its parameter to the default, as the field's value is then
    /// one the recipient ignores). For a field on several lines: parse the first line with this, then call
    /// `appendFieldLine` on the dictionary and this again for each later one.
    ///
    /// - Throws: ``HTTPStructuredFieldError`` if the line isn't valid; nothing is changed then.
    @inlinable
    public mutating func update(from dictionary: inout HTTPStructuredDictionary) throws(HTTPStructuredFieldError) {
        var urgency = urgency, isIncremental = isIncremental
        while let member = try dictionary.next() {
            guard member.key.byteCount == 1 else { continue }
            switch member.key.load(fromByteOffset: 0, as: UInt8.self) {
            case 0x75: // u
                urgency = Self.defaultUrgency
                if case let .item(item) = member.value, case let .integer(value) = item.bareItem, value >= 0, value <= 7 {
                    urgency = Int(value)
                }
            case 0x69: // i
                isIncremental = false
                if case let .item(item) = member.value, case let .boolean(value) = item.bareItem {
                    isIncremental = value
                }
            default:
                break
            }
        }
        self.urgency = urgency
        self.isIncremental = isIncremental
    }

    /// Writes the priority as a field value: `u=N` unless the urgency is 3, `i` if it's incremental, joined by `, `.
    /// The default priority writes nothing (an empty Dictionary): the field can be left out.
    ///
    /// - Throws: ``HTTPStructuredFieldError/insufficientCapacity``; nothing is written then.
    @inlinable
    public func write(to writer: inout AlignedBytesWriter) throws(HTTPStructuredFieldError) {
        let start = writer.position
        do throws(BytesError) {
            if urgency != Self.defaultUrgency {
                try writer.write(0x3D75 as UInt16, as: Byte2.self, .littleEndian) // "u="
                try writer.write(0x30 &+ UInt8(truncatingIfNeeded: urgency))
                if isIncremental { try writer.write(0x69_202C as UInt32, as: Byte3.self, .littleEndian) } // ", i"
            } else if isIncremental {
                try writer.write(0x69 as UInt8)
            }
        } catch {
            writer.rewind(to: start)
            throw .insufficientCapacity
        }
    }

    /// The field value: `u=5, i`, or empty for the default.
    public var description: String {
        var parts: [String] = []
        if urgency != Self.defaultUrgency { parts.append("u=\(urgency)") }
        if isIncremental { parts.append("i") }
        return parts.joined(separator: ", ")
    }
}
