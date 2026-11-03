import CasePathsMacrosSupport
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public enum DiscriminatedDecodableMacro {}

private struct MacroDiagnostic: DiagnosticMessage {
    let message: String
    var diagnosticID: MessageID { MessageID(domain: "DiscriminatedDecoding", id: message) }
    var severity: DiagnosticSeverity { .error }
}

extension DiscriminatedDecodableMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let enumDecl = declaration.as(EnumDeclSyntax.self) else {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(node: Syntax(declaration), message: MacroDiagnostic(message: "@DiscriminatedDecodable can only be applied to an enum"))
            ])
        }

        let cases = enumDecl.memberBlock.members.flatMap { $0.decl.as(EnumCaseDeclSyntax.self)?.elements ?? [] }
        var diagnostics: [Diagnostic] = []
        for element in cases where element.parameterClause?.parameters.count != 1 {
            diagnostics.append(Diagnostic(
                node: Syntax(element),
                message: MacroDiagnostic(message: "@DiscriminatedDecodable requires each case to have exactly one associated value")
            ))
        }
        guard diagnostics.isEmpty else { throw DiagnosticsError(diagnostics: diagnostics) }

        var extensions: [ExtensionDeclSyntax] = []

        // Let CasePathable generate its own conformance extension for only its protocols.
        let casePathProtocols = protocols.filter { ["CasePathable", "CasePathIterable"].contains($0.trimmedDescription) }
        extensions += try CasePathsMacrosSupport.CasePathableMacro.expansion(
            of: node,
            attachedTo: declaration,
            providingExtensionsOf: type,
            conformingTo: casePathProtocols,
            in: context
        )

        guard protocols.contains(where: { $0.trimmedDescription == "Decodable" }) else { return extensions }

        let availability = declaration.attributes.compactMap { element -> AttributeListSyntax.Element? in
            guard case .attribute(let attribute) = element,
                attribute.attributeName.trimmedDescription == "available"
            else { return nil }
            return element
        }

        let decodable = try ExtensionDeclSyntax(
            attributes: AttributeListSyntax(availability),
            extendedType: type.trimmed,
            inheritanceClause: InheritanceClauseSyntax { InheritedTypeSyntax(type: TypeSyntax("Swift.Decodable")) }
        ) {
            try EnumDeclSyntax("private enum CodingKeys: String, Swift.CodingKey") {
                "case kind, attributes"
            }
            try EnumDeclSyntax("private enum Kind: String, Swift.Decodable") {
                for element in cases {
                    "case \(element.name.trimmed)"
                }
            }
            try InitializerDeclSyntax("init(from decoder: any Swift.Decoder) throws") {
                "let container = try decoder.container(keyedBy: CodingKeys.self)"
                try SwitchExprSyntax("switch try container.decode(Kind.self, forKey: .kind)") {
                    for element in cases {
                        SwitchCaseSyntax("case .\(element.name.trimmed):") {
                            "self = .\(element.name.trimmed)(try container.decode(\(element.parameterClause!.parameters.first!.type.trimmed).self, forKey: .attributes))"
                        }
                    }
                }
            }
        }
        extensions.append(decodable)
        return extensions
    }
}

extension DiscriminatedDecodableMacro: MemberMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // The extension macro reports the non-enum diagnostic.
        guard declaration.is(EnumDeclSyntax.self) else { return [] }
        return try CasePathsMacrosSupport.CasePathableMacro.expansion(
            of: node,
            providingMembersOf: declaration,
            in: context
        )
    }
}
