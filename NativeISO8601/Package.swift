// swift-tools-version: 6.4

import PackageDescription

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .strictMemorySafety(),
    // `@_lifetime` lets the non-escapable lexer store and advance over a borrowed `Span`.
    .enableExperimentalFeature("Lifetimes"),
]

let package = Package(
    name: "NativeISO8601",
    platforms: [.macOS(.v27), .iOS(.v27), .tvOS(.v27), .watchOS(.v27), .visionOS(.v27)],
    products: [
        .library(name: "NativeISO8601", targets: ["NativeISO8601"]),
        .executable(name: "iso8601-suite-adapter", targets: ["ISO8601SuiteAdapter"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.38.1"),
    ],
    targets: [
        .target(
            name: "NativeISO8601",
            swiftSettings: strictSettings
        ),
        // Adapter for the CalConnect ISO 8601 conformance suite's `exec:` JSON protocol.
        .executableTarget(
            name: "ISO8601SuiteAdapter",
            dependencies: ["NativeISO8601"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NativeISO8601Tests",
            dependencies: ["NativeISO8601"],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "ISO8601Benchmarks",
            dependencies: [
                "NativeISO8601",
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/ISO8601Benchmarks",
            swiftSettings: [.swiftLanguageMode(.v6), .enableExperimentalFeature("Lifetimes")],
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
    ]
)
