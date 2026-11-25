internal import SwiftCompilerPlugin
internal import SwiftDiagnostics
public import SwiftSyntax
internal import SwiftSyntaxBuilder
public import SwiftSyntaxMacros

@main
struct BytesMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        BitFieldsMacro.self,
        BinaryRecordMacro.self,
        FieldMarkerMacro.self,
    ]
}

/// `@Flag`, `@Field`: markers read by `@BitFields` and `@BinaryRecord`; they expand to nothing themselves.
public struct FieldMarkerMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] { [] }
}

/// An error a macro reports at a node.
struct MacroError: Error, DiagnosticMessage {
    let message: String
    /// The node the error is about (a property), or `nil` for the attribute itself.
    let node: Syntax?
    var diagnosticID: MessageID { MessageID(domain: "BytesMacros", id: "error") }
    var severity: DiagnosticSeverity { .error }
    init(_ message: String, at node: some SyntaxProtocol? = Syntax?.none) {
        self.message = message
        self.node = node.map { Syntax($0) }
    }
}

extension MacroExpansionContext {
    /// Runs a member expansion, reporting an error about a property at the property (errors about the
    /// attribute are reported there by the caller).
    func reportingAtProperties(_ body: () throws -> [DeclSyntax]) throws -> [DeclSyntax] {
        do {
            return try body()
        } catch let error as MacroError {
            guard let node = error.node else { throw error }
            diagnose(Diagnostic(node: node, message: error))
            return []
        }
    }
}

/// A stored property of the struct a macro is attached to, with its marker attribute.
struct MarkedProperty {
    let name: String
    let type: String
    let marker: AttributeSyntax?
    let declaration: VariableDeclSyntax

    var markerName: String? {
        marker?.attributeName.as(IdentifierTypeSyntax.self)?.name.text
    }

    /// The marker's argument labeled `label` (or the first unlabeled one for `nil`), as source text.
    func argument(_ label: String?) -> ExprSyntax? {
        guard case let .argumentList(arguments) = marker?.arguments else { return nil }
        return arguments.first { $0.label?.text == label }?.expression
    }
}

extension DeclGroupSyntax {
    /// The stored properties, in order, with their `@Flag`/`@Field` markers.
    func markedProperties() throws -> [MarkedProperty] {
        var properties: [MarkedProperty] = []
        for member in memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self),
                  !variable.modifiers.contains(where: { $0.name.text == "static" }) else { continue }
            for binding in variable.bindings {
                // Computed properties aren't fields.
                if let accessor = binding.accessorBlock, case .getter = accessor.accessors { continue }
                if let accessor = binding.accessorBlock, case let .accessors(list) = accessor.accessors,
                   list.contains(where: { $0.accessorSpecifier.tokenKind == .keyword(.get) }) { continue }
                guard let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else { continue }
                guard let type = binding.typeAnnotation?.type.trimmedDescription else {
                    throw MacroError("'\(name)' needs a type annotation", at: variable)
                }
                let marker = variable.attributes.compactMap { $0.as(AttributeSyntax.self) }.first {
                    let name = $0.attributeName.as(IdentifierTypeSyntax.self)?.name.text
                    return name == "Flag" || name == "Field"
                }
                properties.append(MarkedProperty(name: name, type: type, marker: marker, declaration: variable))
            }
        }
        return properties
    }

    /// `public ` if the type is public, so generated members match its access.
    var accessPrefix: String {
        modifiers.contains { $0.name.text == "public" || $0.name.text == "package" }
            ? (modifiers.first { $0.name.text == "public" || $0.name.text == "package" }!.name.text + " ") : ""
    }
}

/// The kind of value a field holds, from its declared type.
enum FieldValueKind {
    case bool
    case integer(String)
    case bits(String)
    case rawRepresentable(String)

    init(type: String) {
        switch type {
        case "Bool": self = .bool
        case "Int", "UInt", "Int8", "UInt8", "Int16", "UInt16", "Int32", "UInt32", "Int64", "UInt64": self = .integer(type)
        case "Bit", "Crumb", "Nibble", "Byte": self = .bits(type)
        default:
            if type.hasPrefix("Bits<") { self = .bits(type) } else { self = .rawRepresentable(type) }
        }
    }
}

extension ExprSyntax {
    /// The type a `T.self` expression names, as source text (`Byte4` for `Byte4.self`); the expression's own
    /// text otherwise.
    var metatypeName: String {
        if let member = self.as(MemberAccessExprSyntax.self), member.declName.baseName.text == "self", let base = member.base {
            return base.trimmedDescription
        }
        return trimmedDescription
    }
}
