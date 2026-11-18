// swift-tools-version: 6.4

import PackageDescription

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .strictMemorySafety(),
    // `@_lifetime` lets non-escapable types (Span, RawSpan, ByteReader) be returned and stored.
    .enableExperimentalFeature("Lifetimes"),
]

let package = Package(
    name: "NativeZipArchive",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "NativeZip", targets: ["NativeZip"]),
        .executable(name: "nunzip", targets: ["nunzip"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.38.1"),
        .package(path: "../Bytes"),
    ],
    targets: [
        .target(
            name: "NativeZip",
            dependencies: [
                "CBZip2",
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "BytesMacros", package: "Bytes"),
                .product(name: "BytesFoundation", package: "Bytes"),
                // Streaming DEFLATE for encrypted entries, and zstd.
                .product(name: "BytesCompression", package: "Bytes"),
                // WinZip AES: AES, HMAC-SHA1, PBKDF2.
                .product(name: "BytesCrypto", package: "Bytes"),
            ],
            swiftSettings: strictSettings
        ),
        // libbz2 from the SDK, for bzip2 entries (method 12).
        .systemLibrary(name: "CBZip2", path: "Sources/CBZip2"),
        .executableTarget(
            name: "nunzip",
            dependencies: [
                "NativeZip",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "NativeZipTests",
            dependencies: ["NativeZip"],
            // Archives and vectors the tests load from their own directory (#filePath).
            exclude: ["Fixtures"],
            // Not strict memory safety: the tests call zlib's C API directly to make reference streams.
            swiftSettings: [.swiftLanguageMode(.v6), .enableExperimentalFeature("Lifetimes")]
        ),
        .executableTarget(
            name: "NativeZipBenchmarks",
            dependencies: [
                "NativeZip",
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/NativeZipBenchmarks",
            swiftSettings: [.swiftLanguageMode(.v6)],
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
    ]
)
