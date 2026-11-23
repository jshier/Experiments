// swift-tools-version: 6.4

import PackageDescription

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .strictMemorySafety(),
    // `@_lifetime` lets non-escapable types (Span, RawSpan, ByteReader) be returned and stored.
    .enableExperimentalFeature("Lifetimes"),
    // Async functions run on the caller's executor unless marked `@concurrent` (every one here is annotated).
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "NativeZipArchive",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "NativeZip", targets: ["NativeZip"]),
        .executable(name: "nunzip", targets: ["nunzip"]),
    ],
    // `SyscallCounting` turns on Disk's trait of that name: the benchmarks then report Disk's file system calls
    // (`Disk syscalls`). `swift package --traits SyscallCounting --scratch-path .build-syscalls --disable-sandbox benchmark`
    traits: [
        .trait(name: "SyscallCounting", description: "Count Disk's file system calls (the benchmarks' `Disk syscalls` metric)."),
        .default(enabledTraits: []),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.38.1"),
        .package(path: "../Bytes"),
        // Writing the tree: files, directories, links, metadata, in parallel (and its call counts, with the trait).
        .package(path: "../Disk", traits: [.trait(name: "SyscallCounting", condition: .when(traits: ["SyscallCounting"]))]),
    ],
    targets: [
        .target(
            name: "NativeZip",
            dependencies: [
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "BytesMacros", package: "Bytes"),
                .product(name: "BytesFoundation", package: "Bytes"),
                // Every compression method: DEFLATE and Deflate64, bzip2, LZMA, xz, Zstandard.
                .product(name: "BytesCompression", package: "Bytes"),
                // WinZip AES: AES, HMAC-SHA1, PBKDF2.
                .product(name: "BytesCrypto", package: "Bytes"),
                // The handoff between a large entry's decoding task and its writer (`AsyncHandoff`).
                .product(name: "BytesAsync", package: "Bytes"),
                // Writing the tree, and the mapped archive (`MappedFile`).
                .product(name: "Disk", package: "Disk"),
            ],
            swiftSettings: strictSettings
        ),
        .executableTarget(
            name: "nunzip",
            dependencies: [
                "NativeZip",
                // `DiskError`, for an archive that can't be opened.
                .product(name: "Disk", package: "Disk"),
                // `withPriority`.
                .product(name: "BytesAsync", package: "Bytes"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "NativeZipTests",
            dependencies: [
                "NativeZip",
                .product(name: "Disk", package: "Disk"),
                // Reading extracted trees: items, extended attributes, ACLs.
                .product(name: "DiskTestSupport", package: "Disk"),
                .product(name: "BytesTestSupport", package: "Bytes"),
                .product(name: "BytesTesting", package: "Bytes"),
                .product(name: "BytesReferenceCodecs", package: "Bytes"),
            ],
            // Archives and vectors the tests load from their own directory (#filePath).
            exclude: ["Fixtures"],
            // Not strict memory safety: the tests call zlib's C API directly to make reference streams.
            swiftSettings: [
                .swiftLanguageMode(.v6), .enableExperimentalFeature("Lifetimes"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        .executableTarget(
            name: "NativeZipBenchmarks",
            dependencies: [
                "NativeZip",
                .product(name: "Disk", package: "Disk"),
                // `CRC32` for the CRC-32 rows.
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "BytesTestSupport", package: "Bytes"),
                // Compression's one-shot DEFLATE decoder, the reference row.
                .product(name: "BytesReferenceCodecs", package: "Bytes"),
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/NativeZipBenchmarks",
            swiftSettings: [.swiftLanguageMode(.v6), .enableUpcomingFeature("NonisolatedNonsendingByDefault")],
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
    ]
)
