import Foundation

/// Utilities for turning an opaque `Any` value produced by `PropertyListSerialization` into a
/// human-readable "schema" description: the shape of the data (dictionary keys, array element
/// types, scalar types) without dumping every byte of large blobs.
public enum PlistSchema {
    /// Produces an indented, human-readable tree describing the structure of `value`.
    public static func describe(_ value: Any, indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)

        switch value {
        case let dict as [String: Any]:
            var lines = ["\(pad)Dictionary<String, Any> (\(dict.count) keys)"]
            for key in dict.keys.sorted() {
                let childValue = dict[key]!
                lines.append("\(pad)  - \(key): \(typeName(of: childValue))")
                let child = describe(childValue, indent: indent + 2)
                // Only append nested detail for container/interesting types.
                if childValue is [String: Any] || childValue is [Any] {
                    lines.append(child)
                }
            }
            return lines.joined(separator: "\n")

        case let array as [Any]:
            var lines = ["\(pad)Array<Any> (\(array.count) elements)"]
            for (index, element) in array.enumerated() {
                lines.append("\(pad)  [\(index)]: \(typeName(of: element))")
                if element is [String: Any] || element is [Any] {
                    lines.append(describe(element, indent: indent + 2))
                }
            }
            return lines.joined(separator: "\n")

        default:
            return "\(pad)\(typeName(of: value))"
        }
    }

    /// A short type + value-preview description for a single (typically scalar) value.
    public static func typeName(of value: Any) -> String {
        switch value {
        case let data as Data:
            return "Data (\(data.count) bytes) prefix=\(hexPrefix(of: data))\(archiveHint(for: data))"
        case let string as String:
            return "String = \"\(string)\""
        case let number as NSNumber:
            // NSNumber backs both Bool and numeric plist values; try to distinguish.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return "Bool = \(number.boolValue)"
            }
            return "Number = \(number)"
        case let date as Date:
            return "Date = \(date)"
        case let dict as [String: Any]:
            return "Dictionary<String, Any> (\(dict.count) keys)"
        case let array as [Any]:
            return "Array<Any> (\(array.count) elements)"
        default:
            return "\(Swift.type(of: value))"
        }
    }

    /// First few bytes of `data`, hex-encoded, to help identify embedded formats (e.g. `bplist00`
    /// magic number for a nested keyed-archive) without dumping the whole blob.
    public static func hexPrefix(of data: Data, length: Int = 8) -> String {
        data.prefix(length).map { String(format: "%02x", $0) }.joined()
    }

    /// Heuristic hints about what a `Data` blob might contain, based on well-known magic numbers.
    public static func archiveHint(for data: Data) -> String {
        if data.starts(with: Array("bplist00".utf8)) {
            return " [looks like a nested binary plist / NSKeyedArchiver payload]"
        }
        return ""
    }
}
