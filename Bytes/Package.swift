// swift-tools-version: 6.4

import PackageDescription

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .strictMemorySafety(),
    // `@_lifetime`: `Bytes` is `~Escapable` and hands out spans that borrow the memory it reads.
    .enableExperimentalFeature("Lifetimes"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "Bytes",
    platforms: [.macOS(.v27), .iOS(.v27), .tvOS(.v27), .watchOS(.v27), .visionOS(.v27)],
    products: [
        .library(name: "Bytes", targets: ["Bytes"]),
    ],
    traits: [
        .trait(
            name: "NEONShuffle",
            description: "Pack and unpack odd-width byte groups with NEON table lookups (the CBytesNEON C module)."
        ),
        .default(enabledTraits: ["NEONShuffle"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.38.1"),
    ],
    targets: [
        // NEON `tbl` wrappers Swift inlines; a portable fallback elsewhere.
        .target(name: "CBytesNEON"),
        // Carry-less multiply and CRC32 instruction wrappers for `CRC32`; empty on CPUs without them.
        .target(name: "CBytesCRC"),
        .target(
            name: "Bytes",
            dependencies: [
                .target(name: "CBytesNEON", condition: .when(traits: ["NEONShuffle"])),
                "CBytesCRC",
            ],
            // `import Builtin`, for branch-weight and value-range hints the standard library doesn't expose.
            swiftSettings: strictSettings + [.enableExperimentalFeature("BuiltinModule")]
        ),
        .testTarget(
            name: "BytesTests",
            dependencies: ["Bytes"],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "BytesBenchmarks",
            dependencies: [
                "Bytes",
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/BytesBenchmarks",
            swiftSettings: [.swiftLanguageMode(.v6), .enableExperimentalFeature("Lifetimes")],
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
    ]
)
