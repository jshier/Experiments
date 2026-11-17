import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@BinaryRecord(.littleEndian)`: a fixed-layout record, its fields in order.
///
/// ```swift
/// @BinaryRecord(.littleEndian)
/// struct LocalFileHeader {
///     @Field(Byte4.self, expecting: 0x0403_4B50) var signature: UInt32
///     @Field(Byte2.self) var version: UInt16
///     var flags: GeneralPurposeFlags          // a @BitFields type, or any FixedSizeBinary & BinaryParsable
///     @Field(Byte2.self) var method: CompressionMethod
///     …
/// }
/// ```
///
/// Generates `byteCount` (the sum of the fields' sizes), a memberwise `init`, and `BinaryParsable` and
/// `BinaryWritable` conformances. Parsing takes the record's bytes with one bounds check, then reads each field
/// once from a cursor whose length the optimizer knows, so the per-field checks fold away: the form of Bytes'
/// "fixed-size records" zip parser, which measured 30% fewer instructions than field-by-field reads.
public struct BinaryRecordMacro: MemberMacro, ExtensionMacro {
    struct Field {
        let name: String
        let type: String
        let kind: FieldValueKind
        /// `Byte4` for a `@Field(Byte4.self)`; `nil` for a nested record.
        let group: String?
        let expected: String?

        var byteCount: String {
            if let group { return String(group.dropFirst("Byte".count)) }
            return "\(type).byteCount"
        }
    }

    static func byteOrder(of node: AttributeSyntax) throws -> String {
        guard case let .argumentList(arguments) = node.arguments, let order = arguments.first?.expression else {
            throw MacroError("@BinaryRecord needs a byte order: @BinaryRecord(.littleEndian)")
        }
        return order.trimmedDescription
    }

    static func fields(of declaration: some DeclGroupSyntax) throws -> [Field] {
        try declaration.markedProperties().map { property in
            let kind = FieldValueKind(type: property.type)
            switch property.markerName {
            case "Field":
                guard let group = property.argument(nil)?.metatypeName,
                      group.hasPrefix("Byte"), Int(group.dropFirst(4)) != nil else {
                    throw MacroError("@Field in a @BinaryRecord names its width: @Field(Byte2.self)", at: property.declaration)
                }
                if case .bool = kind { throw MacroError("'\(property.name)': a Bool field belongs in a @BitFields type", at: property.declaration) }
                if case .bits = kind { throw MacroError("'\(property.name)': Bits fields belong in a @BitFields type", at: property.declaration) }
                return Field(name: property.name, type: property.type, kind: kind, group: group,
                             expected: property.argument("expecting")?.trimmedDescription)
            case nil:
                // A nested record: anything FixedSizeBinary & BinaryParsable & BinaryWritable.
                return Field(name: property.name, type: property.type, kind: kind, group: nil, expected: nil)
            default:
                throw MacroError("@\(property.markerName!) belongs in a @BitFields type", at: property.declaration)
            }
        }
    }

    public static func expansion(
        of node: AttributeSyntax, providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try context.reportingAtProperties {
        let fields = try fields(of: declaration)
        let access = declaration.accessPrefix
        let inlinable = access.isEmpty ? "@inline(__always) " : "@inlinable @inline(__always) "
        let parameters = fields.map { field in
            field.expected.map { "\(field.name): \(field.type) = \($0)" } ?? "\(field.name): \(field.type)"
        }.joined(separator: ", ")
        let assignments = fields.map { "self.\($0.name) = \($0.name)" }.joined(separator: "\n")
        let sum = fields.map(\.byteCount).joined(separator: " + ")
        return [
            """
            \(raw: inlinable)\(raw: access)init(\(raw: parameters)) {
            \(raw: assignments)
            }
            """,
            """
            /// The record's size in bytes.
            \(raw: inlinable)\(raw: access)static var byteCount: Int { \(raw: sum.isEmpty ? "0" : sum) }
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
        let order = try byteOrder(of: node)
        let fields = try fields(of: declaration)
        let access = declaration.accessPrefix
        let inlinable = access.isEmpty ? "@inline(__always) " : "@inlinable @inline(__always) "

        var reads: [String] = []
        var writes: [String] = []
        for field in fields {
            guard let group = field.group else {
                reads.append("self.\(field.name) = try \(field.type)(parsing: &record)")
                writes.append("try \(field.name).write(to: &writer)")
                continue
            }
            switch field.kind {
            case .integer(let type):
                // Fixed-width signed types are two's complement fields; `Int` and unsigned types, unsigned values.
                let label = ["Int8", "Int16", "Int32", "Int64"].contains(type) ? "asSigned" : "as"
                if let expected = field.expected {
                    reads.append("""
                        let \(field.name) = try record.read(\(type).self, \(label): \(group).self, \(order))
                        guard \(field.name) == \(expected) else { throw .mismatch }
                        self.\(field.name) = \(field.name)
                        """)
                } else {
                    reads.append("self.\(field.name) = try record.read(\(type).self, \(label): \(group).self, \(order))")
                }
                writes.append("try writer.write(\(field.name), \(label): \(group).self, \(order))")
            default:
                reads.append("self.\(field.name) = try record.read(\(field.type).self, as: \(group).self, \(order))")
                writes.append("try writer.write(\(field.name), as: \(group).self, \(order))")
            }
        }
        let declaration: DeclSyntax = """
            extension \(type.trimmed): BinaryParsable, BinaryWritable, FixedSizeBinary {
            /// Reads the record: its bytes with one bounds check, then each field once. Consumes nothing if it throws.
            \(raw: inlinable)\(raw: access)init<Mode: BytesCursorMode>(parsing reader: inout GenericBytesReader<Mode>) throws(BytesError) {
            let start = reader.position
            var record = AlignedBytesReader(try reader.read(byteCount: Self.byteCount))
            do throws(BytesError) {
            \(raw: reads.joined(separator: "\n"))
            } catch {
            reader.rewind(to: start)
            throw error
            }
            }
            /// Writes the record's fields in order.
            \(raw: inlinable)\(raw: access)func write<Mode: BytesCursorMode>(to writer: inout GenericBytesWriter<Mode>) throws(BytesError) {
            \(raw: writes.joined(separator: "\n"))
            }
            }
            """
        return [declaration.cast(ExtensionDeclSyntax.self)]
        } catch {
            return []
        }
    }
}
