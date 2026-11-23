// swift-tools-version: 6.4

import PackageDescription

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .strictMemorySafety(),
    // `@_lifetime` lets non-escapable types (Span, RawSpan) be returned and stored.
    .enableExperimentalFeature("Lifetimes"),
    // Async functions run on the caller's executor unless marked `@concurrent` (every one here is annotated).
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "NativeAEA",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "NativeAEA", targets: ["NativeAEA"]),
        .executable(name: "nunarchiver", targets: ["nunarchiver"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.38.1"),
        .package(path: "../Bytes"),
        .package(path: "../Disk"),
    ],
    targets: [
        .target(
            name: "NativeAEA",
            dependencies: [
                .product(name: "Bytes", package: "Bytes"),
                // The pipeline's waits: `Continuation`, `WaiterQueue`, `AsyncQueue` (Buffers.swift, BlockStream.swift).
                .product(name: "BytesAsync", package: "Bytes"),
                // LZMA2 (xz) segments.
                .product(name: "BytesCompression", package: "Bytes"),
                // HKDF, HMAC-SHA256, and SHA-256 for the archive's MACs and checksums.
                .product(name: "BytesCrypto", package: "Bytes"),
                // `@BinaryRecord` for the formats' fixed records (AEARecords.swift).
                .product(name: "BytesMacros", package: "Bytes"),
                // The certificates in a xip's table of contents (XAR.swift), and Base64 keys (AEADecryption.swift,
                // WKMS.swift).
                .product(name: "BytesBase64", package: "Bytes"),
                // Writing the tree: the planner, the writers, APFS compression, and metadata (Extraction.swift).
                .product(name: "Disk", package: "Disk"),
            ],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "nunarchiver",
            dependencies: [
                "NativeAEA",
                // `ExtractionProgress`, for `--progress`.
                .product(name: "Disk", package: "Disk"),
                // `String(hexadecimal:)`, `withPriority`.
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "BytesAsync", package: "Bytes"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "NativeAEATests",
            dependencies: [
                "NativeAEA",
                // `ExtractionProgress`, for the progress test.
                .product(name: "Disk", package: "Disk"),
                // Reading extracted trees: items, extended attributes, ACLs, `decmpfs`.
                .product(name: "DiskTestSupport", package: "Disk"),
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "BytesAsync", package: "Bytes"),
                .product(name: "BytesCrypto", package: "Bytes"),
                .product(name: "BytesTestSupport", package: "Bytes"),
                .product(name: "BytesTesting", package: "Bytes"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6), .enableExperimentalFeature("Lifetimes"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .executableTarget(
            name: "NativeAEABenchmarks",
            dependencies: [
                "NativeAEA",
                // `ExtractionProgress`, for the progress benchmark.
                .product(name: "Disk", package: "Disk"),
                // The segment benchmarks' decoders: BytesCompression's, and Compression's as the reference.
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "BytesCompression", package: "Bytes"),
                .product(name: "BytesReferenceCodecs", package: "Bytes"),
                .product(name: "BytesTestSupport", package: "Bytes"),
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/NativeAEABenchmarks",
            swiftSettings: [
                .swiftLanguageMode(.v6), .enableExperimentalFeature("Lifetimes"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ],
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
    ]
)
