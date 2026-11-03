// swift-tools-version: 6.0

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "DiscriminatedDecoding",
    platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16), .watchOS(.v9)],
    products: [
        .library(name: "DiscriminatedDecoding", targets: ["DiscriminatedDecoding"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-case-paths", from: "1.10.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax", "509.0.0"..<"605.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-macro-testing", from: "0.6.0"),
    ],
    targets: [
        .macro(
            name: "DiscriminatedDecodingMacros",
            dependencies: [
                .product(name: "CasePathsMacrosSupport", package: "swift-case-paths"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "DiscriminatedDecoding",
            dependencies: [
                "DiscriminatedDecodingMacros",
                .product(name: "CasePaths", package: "swift-case-paths"),
            ]
        ),
        .testTarget(
            name: "DiscriminatedDecodingTests",
            dependencies: [
                "DiscriminatedDecoding",
            ]
        ),
        .testTarget(
            name: "DiscriminatedDecodingMacrosTests",
            dependencies: [
                "DiscriminatedDecodingMacros",
                .product(name: "MacroTesting", package: "swift-macro-testing"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
