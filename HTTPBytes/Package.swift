// swift-tools-version: 6.4

import PackageDescription

// Swift 6 language mode, and the upcoming features Bytes uses: imports internal unless `public import`, async functions on
// their caller's executor unless `@concurrent` (`NonisolatedNonsendingByDefault`), and the rest of Swift 7's set.
let commonSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    // `@_lifetime`: parsers hand out `~Escapable` views of the bytes they read.
    .enableExperimentalFeature("Lifetimes"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
]
// Library targets: every `unsafe` expression marked, with its reason.
let strictSettings: [SwiftSetting] = commonSettings + [.strictMemorySafety()]

let package = Package(
    name: "HTTPBytes",
    platforms: [.macOS(.v27), .iOS(.v27), .tvOS(.v27), .watchOS(.v27), .visionOS(.v27)],
    products: [
        // HTTP's shared semantics: methods, status codes, field names and values, targets, dates, Structured Fields,
        // and HPACK's and QPACK's shared Huffman code and integers.
        .library(name: "HTTPBytes", targets: ["HTTPBytes"]),
        // HTTP/1.1 messages: heads, body framing, chunked coding (RFC 9112).
        .library(name: "HTTP1", targets: ["HTTP1"]),
        // HTTP/2 frames and HPACK (RFC 9113, RFC 7541).
        .library(name: "HTTP2", targets: ["HTTP2"]),
        // HTTP/3 frames and QPACK (RFC 9114, RFC 9204).
        .library(name: "HTTP3", targets: ["HTTP3"]),
        // Content codings over BytesCompression.
        .library(name: "HTTPPayload", targets: ["HTTPPayload"]),
        // Conversions to and from swift-http-types.
        .library(name: "HTTPBytesHTTPTypes", targets: ["HTTPBytesHTTPTypes"]),
    ],
    dependencies: [
        .package(path: "../Bytes"),
        .package(path: "../BytesCompression"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.8.0"),
    ],
    targets: [
        .target(
            name: "HTTPBytes",
            // BytesBase64: Structured Fields' byte sequences.
            dependencies: [.product(name: "Bytes", package: "Bytes"), .product(name: "BytesBase64", package: "Bytes")],
            swiftSettings: strictSettings
        ),
        .target(
            name: "HTTP1",
            dependencies: ["HTTPBytes", .product(name: "Bytes", package: "Bytes")],
            swiftSettings: strictSettings
        ),
        .target(
            name: "HTTP2",
            dependencies: [
                "HTTPBytes",
                .product(name: "Bytes", package: "Bytes"),
                // `@BinaryRecord` frame headers, `@BitFields` flags.
                .product(name: "BytesMacros", package: "Bytes"),
            ],
            swiftSettings: strictSettings
        ),
        .target(
            name: "HTTP3",
            dependencies: ["HTTPBytes", .product(name: "Bytes", package: "Bytes")],
            swiftSettings: strictSettings
        ),
        .target(
            name: "HTTPPayload",
            dependencies: [
                "HTTPBytes",
                "HTTP1",
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "BytesCompression", package: "BytesCompression"),
            ],
            swiftSettings: strictSettings
        ),
        .target(
            name: "HTTPBytesHTTPTypes",
            dependencies: [
                "HTTPBytes",
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "HTTPBytesTests",
            dependencies: [
                "HTTPBytes",
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "BytesTestSupport", package: "Bytes"),
                .product(name: "BytesTesting", package: "Bytes"),
            ],
            swiftSettings: commonSettings
        ),
        .testTarget(
            name: "HTTP1Tests",
            dependencies: [
                "HTTP1", "HTTPBytes",
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "BytesTestSupport", package: "Bytes"),
                .product(name: "BytesTesting", package: "Bytes"),
            ],
            swiftSettings: commonSettings
        ),
        .testTarget(
            name: "HTTP2Tests",
            dependencies: [
                "HTTP2", "HTTPBytes",
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "BytesTestSupport", package: "Bytes"),
                .product(name: "BytesTesting", package: "Bytes"),
            ],
            swiftSettings: commonSettings
        ),
        .testTarget(
            name: "HTTP3Tests",
            dependencies: [
                "HTTP3", "HTTPBytes",
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "BytesTestSupport", package: "Bytes"),
                .product(name: "BytesTesting", package: "Bytes"),
            ],
            swiftSettings: commonSettings
        ),
        .testTarget(
            name: "HTTPPayloadTests",
            dependencies: [
                "HTTPPayload", "HTTP1", "HTTPBytes",
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "BytesCompression", package: "BytesCompression"),
                .product(name: "BytesTestSupport", package: "Bytes"),
                .product(name: "BytesTesting", package: "Bytes"),
            ],
            swiftSettings: commonSettings
        ),
        .testTarget(
            name: "HTTPBytesHTTPTypesTests",
            dependencies: ["HTTPBytesHTTPTypes", "HTTPBytes", .product(name: "HTTPTypes", package: "swift-http-types")],
            swiftSettings: commonSettings
        ),
    ]
)
