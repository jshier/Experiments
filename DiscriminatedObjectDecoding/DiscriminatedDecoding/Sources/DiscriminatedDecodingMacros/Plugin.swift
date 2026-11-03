import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct DiscriminatedDecodingPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [DiscriminatedDecodableMacro.self]
}
