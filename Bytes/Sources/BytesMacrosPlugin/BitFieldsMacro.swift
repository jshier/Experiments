import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@BitFields(Byte.self, reserved: 0...0)`: a struct of flags and fields packed into one value.
///
/// Generates `init(rawValue:) throws(BytesError)` (decoding every field, checking the reserved bits), `rawValue`
/// (encoding), a memberwise `init`, and `BinaryParsable`, `BinaryWritable`, and `FixedSizeBinary` conformances,
/// so a reader reads it in one call: `try reader.read(ConnectFlags.self)`.
public struct BitFieldsMacro: MemberMacro, ExtensionMacro {
    /// The storage type and how it's read and written.
    struct Storage {
        let type: String
        let byteCount: Int
        let bitCount: Int
        /// The byte order, for storage wider than a byte; `nil` there for the cursor's.
        let byteOrder: String?

        /// Whether the fields are stored in the byte order of the cursor that reads them.
        var inCursorOrder: Bool { byteCount > 1 && byteOrder == nil }

        var zero: String { type == "Byte" ? "Byte.zero" : "0" }

        func read(_ reader: String) -> String {
            switch type {
            case "Byte": "\(reader).read(Byte.self)"
            case "UInt8": "\(reader).read(UInt8.self)"
            default: byteOrder.map { "\(reader).read(Byte\(byteCount).self, \($0))" } ?? "\(reader).read(\(type).self)"
            }
        }

        func write(_ value: String, _ writer: String) -> String {
            switch type {
            case "Byte", "UInt8": "\(writer).write(\(value))"
            default: byteOrder.map { "\(writer).write(\(value), as: Byte\(byteCount).self, \($0))" } ?? "\(writer).write(\(value))"
            }
        }
    }

    static func storage(of node: AttributeSyntax) throws -> Storage {
        guard case let .argumentList(arguments) = node.arguments, let first = arguments.first else {
            throw MacroError("@BitFields needs its storage type: @BitFields(Byte.self)")
        }
        let type = first.expression.metatypeName
        let order = arguments.dropFirst().first { $0.label == nil }?.expression.trimmedDescription
        switch type {
        case "Byte", "UInt8": return Storage(type: type, byteCount: 1, bitCount: 8, byteOrder: nil)
        case "UInt16", "UInt32", "UInt64":
            let bytes = type == "UInt16" ? 2 : type == "UInt32" ? 4 : 8
            // Without a byte order, the cursor's: read only from byte-ordered cursors.
            return Storage(type: type, byteCount: bytes, bitCount: bytes * 8, byteOrder: order)
        default:
            throw MacroError("@BitFields stores its fields in Byte, UInt8, UInt16, UInt32, or UInt64, not \(type)")
        }
    }

    /// Each property's descriptor expression, kind, and name.
    struct Field {
        let name: String
        let type: String
        let kind: FieldValueKind
        /// `BitFlag(bit: 7)` or `BitField<…>(bits: 3...4)`.
        let descriptor: String
    }

    static func fields(of declaration: some DeclGroupSyntax, storage: Storage) throws -> [Field] {
        try declaration.markedProperties().map { property in
            let kind = FieldValueKind(type: property.type)
            switch property.markerName {
            case "Flag":
                guard case .bool = kind else { throw MacroError("@Flag '\(property.name)' must be a Bool", at: property.declaration) }
                if let bit = property.argument("bit") {
                    return Field(name: property.name, type: property.type, kind: kind, descriptor: "BitFlag(bit: \(bit.trimmedDescription))")
                }
                if let bit = property.argument("bitFromMostSignificant") {
                    return Field(name: property.name, type: property.type, kind: kind,
                                 descriptor: "BitFlag(bitFromMostSignificant: \(bit.trimmedDescription), of: \(storage.bitCount))")
                }
                throw MacroError("@Flag needs bit: or bitFromMostSignificant:", at: property.declaration)
            case "Field":
                let valueType: String = switch kind {
                case .bool: throw MacroError("A Bool field is a @Flag", at: property.declaration)
                case .integer: "Int"
                case .bits(let type), .rawRepresentable(let type): type
                }
                if let bits = property.argument("bits") {
                    return Field(name: property.name, type: property.type, kind: kind,
                                 descriptor: "BitField<\(valueType)>(bits: \(bits.trimmedDescription))")
                }
                if let bits = property.argument("bitsFromMostSignificant") {
                    return Field(name: property.name, type: property.type, kind: kind,
                                 descriptor: "BitField<\(valueType)>(bitsFromMostSignificant: \(bits.trimmedDescription), of: \(storage.bitCount))")
                }
                throw MacroError("@Field needs bits: or bitsFromMostSignificant:", at: property.declaration)
            default:
                throw MacroError("'\(property.name)' needs @Flag or @Field: every stored property of a @BitFields struct is a field", at: property.declaration)
            }
        }
    }

    static func reservedRanges(of node: AttributeSyntax) -> [String] {
        guard case let .argumentList(arguments) = node.arguments else { return [] }
        var ranges: [String] = []
        var collecting = false
        for argument in arguments {
            if argument.label?.text == "reserved" { collecting = true } else if argument.label != nil { collecting = false }
            if collecting { ranges.append(argument.expression.trimmedDescription) }
        }
        return ranges
    }

    public static func expansion(
        of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try context.reportingAtProperties {
        let storage = try storage(of: node)
        let fields = try fields(of: declaration, storage: storage)
        let access = declaration.accessPrefix
        let inlinable = access.isEmpty ? "@inline(__always) " : "@inlinable @inline(__always) "

        var decode = reservedRanges(of: node).map { "try rawValue.requireZero(BitField<Int>(bits: \($0)))" }
        var encode: [String] = []
        for field in fields {
            switch field.kind {
            case .bool, .bits:
                decode.append("self.\(field.name) = rawValue[\(field.descriptor)]")
                encode.append("raw[\(field.descriptor)] = \(field.name)")
            case .integer(let type):
                decode.append("self.\(field.name) = \(type)(truncatingIfNeeded: rawValue[\(field.descriptor)])")
                encode.append("raw[\(field.descriptor)] = Int(\(field.name))")
            case .rawRepresentable:
                decode.append("self.\(field.name) = try rawValue.value(of: \(field.descriptor))")
                encode.append("raw[\(field.descriptor)] = \(field.name)")
            }
        }
        let parameters = fields.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
        let assignments = fields.map { "self.\($0.name) = \($0.name)" }.joined(separator: "\n")

        return [
            """
            \(raw: inlinable)\(raw: access)init(\(raw: parameters)) {
            \(raw: assignments)
            }
            """,
            """
            /// Decodes every field from `rawValue`, checking its reserved bits.
            ///
            /// - Throws: `BytesError.invalidValue` if a reserved bit is set or a field has no matching case.
            \(raw: inlinable)\(raw: access)init(rawValue: \(raw: storage.type)) throws(BytesError) {
            \(raw: decode.joined(separator: "\n"))
            }
            """,
            """
            /// The fields packed into one value.
            \(raw: inlinable)\(raw: access)var rawValue: \(raw: storage.type) {
            var raw: \(raw: storage.type) = \(raw: storage.zero)
            \(raw: encode.joined(separator: "\n"))
            return raw
            }
            """,
        ]
        }
    }

    public static func expansion(
        of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax, providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // Errors are reported once, by the member expansion: here they just mean no extension.
        do {
        let storage = try storage(of: node)
        let access = declaration.accessPrefix
        let inlinable = access.isEmpty ? "@inline(__always) " : "@inlinable @inline(__always) "
        let (conformances, mode) = storage.inCursorOrder
            ? ("ByteOrderedParsable, ByteOrderedWritable", "ByteOrderedCursorMode")
            : ("BinaryParsable, BinaryWritable", "BytesCursorMode")
        let declaration: DeclSyntax = """
            extension \(type.trimmed): \(raw: conformances), FixedSizeBinary {
            \(raw: inlinable)\(raw: access)init<Mode: \(raw: mode)>(parsing reader: inout GenericBytesReader<Mode>) throws(BytesError) {
            try self.init(rawValue: \(raw: storage.read("reader")))
            }
            \(raw: inlinable)\(raw: access)func write<Mode: \(raw: mode)>(to writer: inout GenericBytesWriter<Mode>) throws(BytesError) {
            try \(raw: storage.write("rawValue", "writer"))
            }
            \(raw: inlinable)\(raw: access)static var byteCount: Int { \(raw: storage.byteCount) }
            }
            """
        return [declaration.cast(ExtensionDeclSyntax.self)]
        } catch {
            return []
        }
    }
}
