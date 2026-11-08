// swift-tools-version: 6.4

import PackageDescription

// Benchmarks `Bytes` (../Bytes) against Apple's swift-binary-parsing (`BinaryParsing`) on the same work:
// our parsers ported to `ParserSpan`, and two of its example parsers (QOI, LZ4) ported to `Bytes`.

let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableExperimentalFeature("Lifetimes"),
]

let package = Package(
    name: "BinaryParsingComparison",
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(path: "../Bytes"),
        .package(url: "https://github.com/apple/swift-binary-parsing", .upToNextMinor(from: "0.0.4")),
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.38.1"),
    ],
    targets: [
        .target(
            name: "Workloads",
            dependencies: [
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "BinaryParsing", package: "swift-binary-parsing"),
            ],
            swiftSettings: settings
        ),
        .testTarget(name: "WorkloadsTests", dependencies: ["Workloads"], swiftSettings: settings),
        .executableTarget(
            name: "ComparisonBenchmarks",
            dependencies: ["Workloads", .product(name: "Benchmark", package: "benchmark")],
            path: "Benchmarks/ComparisonBenchmarks",
            swiftSettings: settings,
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
    ]
)
