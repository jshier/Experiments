public import SwiftSyntax
internal import SwiftSyntaxBuilder
public import SwiftSyntaxMacros

/// `@BinaryRecord(.littleEndian)`: a fixed-layout record, its fields in order. `@BinaryRecord` without a byte
/// order: the same, its integers in the byte order of the cursor that reads it.
///
/// ```swift
/// @BinaryRecord(.littleEndian)
/// struct LocalFileHeader {
///     @Field(Byte4.self, expecting: 0x0403_4B50) var signature: UInt32
///     @Field(Byte2.self) var version: UInt16
///     var flags: GeneralPurposeFlags          // a @BitFields type, or any FixedSizeBinary & BinaryParsable
///     @Field(Byte2.self) var method: CompressionMethod
///     @Field(Byte.self) var count: UInt8      // one byte
///     var unused: Padding<Byte2>              // skipped; Reserved<Byte2> must be zero
///     …
/// }
/// ```
///
/// Generates `byteCount` (the sum of the fields' sizes), a memberwise `init`, and `BinaryParsable` and
/// `BinaryWritable` conformances (`ByteOrderedParsable` and `ByteOrderedWritable` for a record in the cursor's
/// order). Parsing takes the record's bytes with one bounds check, then reads each field once from a cursor
/// whose length the optimizer knows, so the per-field checks fold away: the form of Bytes' "fixed-size records"
/// zip parser, which measured 30% fewer instructions than field-by-field reads.
public struct BinaryRecordMacro: MemberMacro, ExtensionMacro {
    struct Field {
        let name: String
        let type: String
        let kind: FieldValueKind
        /// `Byte4` for a `@Field(Byte4.self)`, `Byte` for a `@Field(Byte.self)`; `nil` for a nested record.
        let group: String?
        let expected: String?

        var byteCount: String {
            guard let group else { return "\(type).byteCount" }
            return group == "Byte" ? "1" : String(group.dropFirst("Byte".count))
        }

        /// A `Padding<…>` or `Reserved<…>` field, which holds no value: its initializer parameter defaults.
        var isFiller: Bool { group == nil && (type.hasPrefix("Padding<") || type.hasPrefix("Reserved<")) }
    }

    /// The byte order the attribute names, or `nil` for the cursor's.
    static func byteOrder(of node: AttributeSyntax) -> String? {
        guard case let .argumentList(arguments) = node.arguments, let order = arguments.first?.expression else { return nil }
        return order.trimmedDescription
    }

    static func fields(of declaration: some DeclGroupSyntax) throws -> [Field] {
        try declaration.markedProperties().map { property in
            let kind = FieldValueKind(type: property.type)
            switch property.markerName {
            case "Field":
                guard let group = property.argument(nil)?.metatypeName,
                      group == "Byte" || group.hasPrefix("Byte") && Int(group.dropFirst(4)) != nil else {
                    throw MacroError("@Field in a @BinaryRecord names its width: @Field(Byte2.self), or @Field(Byte.self) for one byte",
                                     at: property.declaration)
                }
                if case .bool = kind { throw MacroError("'\(property.name)': a Bool field belongs in a @BitFields type", at: property.declaration) }
                if case .bits = kind { throw MacroError("'\(property.name)': Bits fields belong in a @BitFields type", at: property.declaration) }
                return Field(name: property.name, type: property.type, kind: kind, group: group,
                             expected: property.argument("expecting")?.trimmedDescription)
            case nil:
                // A nested record (anything FixedSizeBinary & BinaryParsable & BinaryWritable), or Padding/Reserved.
                return Field(name: property.name, type: property.type, kind: kind, group: nil, expected: nil)
            case let name?:
                throw MacroError("@\(name) belongs in a @BitFields type", at: property.declaration)
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
            if let expected = field.expected { return "\(field.name): \(field.type) = \(expected)" }
            if field.isFiller { return "\(field.name): \(field.type) = .init()" }
            return "\(field.name): \(field.type)"
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

    /// The statements reading `field` from `record` and writing it to `writer`. `order` is the byte order
    /// argument (`, .littleEndian`), or empty for a record in the cursor's order.
    static func code(for field: Field, order: String) -> (read: String, write: String) {
        guard let group = field.group else {
            return ("self.\(field.name) = try \(field.type)(parsing: &record)", "try \(field.name).write(to: &writer)")
        }
        let name = field.name
        // The value read, as an expression, and the statement writing `name`.
        let value: String
        let write: String
        switch (group, field.kind) {
        case ("Byte", .integer("UInt8")), ("Byte", .integer("Int8")):
            value = "try record.read(\(field.type).self)"
            write = "try writer.write(\(name))"
        case ("Byte", .integer(let type)):
            // Fixed-width signed types are two's complement fields; `Int` and unsigned types, unsigned values.
            let byte = ["Int16", "Int32", "Int64"].contains(type) ? "Int8" : "UInt8"
            value = "\(type)(try record.read(\(byte).self))"
            write = """
                guard let \(name) = \(byte)(exactly: \(name)) else { throw .invalidValue }
                try writer.write(\(name))
                """
        case ("Byte", _):
            value = "try record.read(\(field.type).self, as: Byte.self)"
            write = "try writer.write(\(name), as: Byte.self)"
        case (_, .integer(let type)):
            let label = ["Int8", "Int16", "Int32", "Int64"].contains(type) ? "asSigned" : "as"
            value = "try record.read(\(type).self, \(label): \(group).self\(order))"
            write = "try writer.write(\(name), \(label): \(group).self\(order))"
        default:
            value = "try record.read(\(field.type).self, as: \(group).self\(order))"
            write = "try writer.write(\(name), as: \(group).self\(order))"
        }
        guard let expected = field.expected else { return ("self.\(name) = \(value)", write) }
        return ("""
            let \(name) = \(value)
            guard \(name) == \(expected) else { throw .mismatch }
            self.\(name) = \(name)
            """, write)
    }

    public static func expansion(
        of node: AttributeSyntax, attachedTo declaration: some DeclGroupSyntax, providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax], in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        // Errors are reported once, by the member expansion: here they just mean no extension.
        do {
        let order = byteOrder(of: node)
        let fields = try fields(of: declaration)
        let access = declaration.accessPrefix
        let inlinable = access.isEmpty ? "@inline(__always) " : "@inlinable @inline(__always) "
        let code = fields.map { Self.code(for: $0, order: order.map { ", \($0)" } ?? "") }
        // A fixed order reads from a byte-aligned cursor over the record, from any reader; the cursor's order,
        // from a cursor in the same (byte-ordered) mode.
        let (conformances, mode, recordReader) = order == nil
            ? ("ByteOrderedParsable, ByteOrderedWritable", "ByteOrderedCursorMode", "GenericBytesReader<Mode>")
            : ("BinaryParsable, BinaryWritable", "BytesCursorMode", "AlignedBytesReader")
        let declaration: DeclSyntax = """
            extension \(type.trimmed): \(raw: conformances), FixedSizeBinary {
            /// Reads the record: its bytes with one bounds check, then each field once. Consumes nothing if it throws.
            \(raw: inlinable)\(raw: access)init<Mode: \(raw: mode)>(parsing reader: inout GenericBytesReader<Mode>) throws(BytesError) {
            let start = reader.position
            var record = \(raw: recordReader)(try reader.read(byteCount: Self.byteCount))
            do throws(BytesError) {
            \(raw: code.map(\.read).joined(separator: "\n"))
            } catch {
            reader.rewind(to: start)
            throw error
            }
            }
            /// Writes the record's fields in order.
            \(raw: inlinable)\(raw: access)func write<Mode: \(raw: mode)>(to writer: inout GenericBytesWriter<Mode>) throws(BytesError) {
            \(raw: code.map(\.write).joined(separator: "\n"))
            }
            }
            """
        return [declaration.cast(ExtensionDeclSyntax.self)]
        } catch {
            return []
        }
    }
}
