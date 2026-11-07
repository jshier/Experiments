// swift-tools-version: 6.4

import PackageDescription

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .strictMemorySafety(),
    // `@_lifetime`: packets are `~Escapable` views of the bytes they were parsed from.
    .enableExperimentalFeature("Lifetimes"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "MQTT",
    platforms: [.macOS(.v27), .iOS(.v27), .tvOS(.v27), .watchOS(.v27), .visionOS(.v27)],
    products: [
        .library(name: "MQTT", targets: ["MQTT"]),
    ],
    dependencies: [
        .package(path: "../Bytes"),
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.38.1"),
    ],
    targets: [
        .target(
            name: "MQTT",
            dependencies: [.product(name: "Bytes", package: "Bytes")],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "MQTTTests",
            dependencies: ["MQTT", .product(name: "Bytes", package: "Bytes")],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "MQTTBenchmarks",
            dependencies: [
                "MQTT",
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/MQTTBenchmarks",
            swiftSettings: [.swiftLanguageMode(.v6), .enableExperimentalFeature("Lifetimes")],
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
    ]
)
