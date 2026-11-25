// swift-tools-version: 6.4

import PackageDescription

// HTTPBytes' benchmarks, a package of their own so the library builds and tests without their references: C parsers
// (picohttpparser, llhttp, cursed-http, ls-hpack, ls-qpack) built from the pinned sources `Tools/test-data fetch`
// puts in the repository's TestData/, and swift-http-types. Run from this directory:
//
//     swift package --disable-sandbox benchmark baseline update NAME --no-progress
//     Tools/bench-table HTTPBytes/Benchmarks OLD NEW      (from the repository root)
//
// Needs `Tools/test-data fetch qifs http-corpus picohttpparser llhttp cursed-http http-top1k ls-hpack ls-qpack hpack-test-case`.

let testData = Context.packageDirectory + "/../../TestData"

let package = Package(
    name: "HTTPBytesBenchmarks",
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(path: ".."),
        .package(path: "../../Bytes"),
        .package(path: "../../BytesCompression"),
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.38.1"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.8.0"),
        // NIOHPACK: HPACK as Swift servers do it today.
        .package(url: "https://github.com/apple/swift-nio-http2", from: "1.46.0"),
        // Structured Field Values as Swift servers parse them today (swift-nio's ecosystem).
        .package(url: "https://github.com/apple/swift-http-structured-headers", from: "1.7.0"),
    ],
    targets: [
        // The references, as their projects build them for speed: -O3, asserts off.
        .target(
            name: "CReferences",
            cSettings: [
                .define("NDEBUG"),
                .define("XXH_HEADER_NAME", to: "\"xxhash.h\""),
                .unsafeFlags(["-O3", "-I\(testData)/llhttp/include", "-I\(testData)/picohttpparser",
                              "-I\(testData)/ls-hpack", "-I\(testData)/ls-hpack/deps/xxhash",
                              "-I\(testData)/ls-qpack"]),
            ]
        ),
        .executableTarget(
            name: "HTTPBytesBenchmarks",
            dependencies: [
                "CReferences",
                .product(name: "HTTPBytes", package: "HTTPBytes"),
                .product(name: "HTTP1", package: "HTTPBytes"),
                .product(name: "HTTP2", package: "HTTPBytes"),
                .product(name: "HTTP3", package: "HTTPBytes"),
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "BytesTestSupport", package: "Bytes"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOHPACK", package: "swift-nio-http2"),
                .product(name: "RawStructuredFieldValues", package: "swift-http-structured-headers"),
                .product(name: "HTTPPayload", package: "HTTPBytes"),
                .product(name: "BytesCompression", package: "BytesCompression"),
                // System zlib, the reference row for content decoding.
                .product(name: "BytesReferenceCodecs", package: "BytesCompression"),
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/HTTPBytesBenchmarks",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableExperimentalFeature("Lifetimes"),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ],
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
    ]
)
