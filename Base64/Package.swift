// swift-tools-version: 6.4

import PackageDescription

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .strictMemorySafety(),
    // `@_lifetime`: the encoder reads and writes through Bytes' `~Escapable` cursors and spans.
    .enableExperimentalFeature("Lifetimes"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "Base64",
    platforms: [.macOS(.v27), .iOS(.v27), .tvOS(.v27), .watchOS(.v27), .visionOS(.v27)],
    products: [
        .library(name: "Base64", targets: ["Base64"]),
    ],
    dependencies: [
        .package(path: "../Bytes"),
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.38.1"),
    ],
    targets: [
        .target(
            name: "Base64",
            dependencies: [.product(name: "Bytes", package: "Bytes")],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "Base64Tests",
            dependencies: ["Base64", .product(name: "Bytes", package: "Bytes")],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "Base64Benchmarks",
            dependencies: [
                "Base64",
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/Base64Benchmarks",
            swiftSettings: [.swiftLanguageMode(.v6), .enableExperimentalFeature("Lifetimes")],
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
    ]
)
