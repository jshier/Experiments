@_exported import CasePaths

/// Makes an enum whose cases each wrap a single `Decodable` payload decodable from
/// `{ "kind": "<caseName>", "attributes": { ... } }`, and applies `@CasePathable`.
///
/// The case name is the discriminator; the payload is decoded from `attributes`.
@attached(extension, conformances: Decodable, CasePathable, CasePathIterable, names: named(CodingKeys), named(Kind), named(init(from:)))
@attached(member, names: named(AllCasePaths), named(allCasePaths), named(_$Element))
public macro DiscriminatedDecodable() =
    #externalMacro(module: "DiscriminatedDecodingMacros", type: "DiscriminatedDecodableMacro")
