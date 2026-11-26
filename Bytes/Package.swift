// swift-tools-version: 6.4

import CompilerPluginSupport
import PackageDescription

// Swift 6 language mode is the default at tools-version 6.4. Every target gets `commonSettings`: Swift 7's upcoming
// features, so the code is written as Swift 7 will need it. Library targets also get strict memory safety
// (`strictSettings`): every `unsafe` expression marked, with a comment saying why it's safe.
let commonSettings: [SwiftSetting] = [
    // `@_lifetime`: `Bytes` is `~Escapable` and hands out spans that borrow the memory it reads.
    .enableExperimentalFeature("Lifetimes"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    // Imports are internal unless marked `public import` (inlinable code and public API need the module).
    .enableUpcomingFeature("InternalImportsByDefault"),
    // A plain `nonisolated async` function runs on its caller's executor; work meant to leave it is `@concurrent`.
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
]
let strictSettings: [SwiftSetting] = commonSettings + [.strictMemorySafety()]

// The `Portable` trait defines `BYTES_PORTABLE` for the C headers. Swift modules compile the headers'
// `static inline` functions themselves, including ones inlined from `Bytes` into the module using it, so
// each Swift target here needs the define too (SwiftPM doesn't pass a C target's defines to its users, and has no
// Swift setting for a Clang define but `unsafeFlags`).
let portableCSettings: [CSetting] = [.define("BYTES_PORTABLE", .when(traits: ["Portable"]))]
let portableSwiftSettings: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-DBYTES_PORTABLE"], .when(traits: ["Portable"]))]

// `@BitFields` and `@BinaryRecord`: packed flags and fixed records that read and write themselves. (`.macro` needs
// `import CompilerPluginSupport`; without it the manifest fails as "unable to type-check this expression in
// reasonable time" rather than naming `.macro`: ~/Scratch/swift-bugs/27.)
let macroTargets: [Target] = [
    .macro(
        name: "BytesMacrosPlugin",
        dependencies: [
            .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        ],
        swiftSettings: commonSettings
    ),
    .target(
        name: "BytesMacros",
        dependencies: ["Bytes", "BytesMacrosPlugin"],
        swiftSettings: strictSettings + portableSwiftSettings
    ),
    .testTarget(
        name: "BytesMacrosTests",
        dependencies: [
            "Bytes",
            "BytesMacros",
            "BytesMacrosPlugin",
            .product(name: "MacroTesting", package: "swift-macro-testing"),
        ],
        swiftSettings: commonSettings + portableSwiftSettings
    ),
]

// Helpers for tests and benchmarks across the repository's packages: not library API. `BytesTestSupport` has no
// Swift Testing dependency, so benchmark executables and other packages' sources (SocketStream's workloads) can use
// it; `BytesTesting` adds what needs Swift Testing (the `.bulk` trait). (`BytesReferenceCodecs`, the SDK's zlib and
// Compression as reference codecs, moved with BytesCompression to its package.)
let supportTargets: [Target] = [
    .target(
        name: "BytesTestSupport",
        swiftSettings: strictSettings
    ),
    .target(
        name: "BytesTesting",
        dependencies: ["BytesTestSupport"],
        swiftSettings: strictSettings
    ),
]

let package = Package(
    name: "Bytes",
    platforms: [.macOS(.v27), .iOS(.v27), .tvOS(.v27), .watchOS(.v27), .visionOS(.v27)],
    products: [
        .library(name: "Bytes", targets: ["Bytes"]),
        // (BytesCompression is a package of its own, ../BytesCompression, since 2026-11-23.)
        .library(name: "BytesCrypto", targets: ["BytesCrypto"]),
        .library(name: "BytesAsync", targets: ["BytesAsync"]),
        .library(name: "BytesMacros", targets: ["BytesMacros"]),
        .library(name: "BytesFoundation", targets: ["BytesFoundation"]),
        .library(name: "BytesBase64", targets: ["BytesBase64"]),
        // Test and benchmark support (above).
        .library(name: "BytesTestSupport", targets: ["BytesTestSupport"]),
        .library(name: "BytesTesting", targets: ["BytesTesting"]),
    ],
    // Three builds, for measuring each (see Benchmarks/RESULTS.md):
    // - default: the C modules' NEON and CRC instructions (what Apple silicon gets);
    // - `--traits Portable`: the C modules' portable fallbacks (what other CPUs get), on Apple silicon;
    // - `--disable-default-traits`: no C modules, Swift only.
    traits: [
        .trait(
            name: "NEONShuffle",
            description: "Pack and unpack odd-width byte groups with NEON table lookups (the CBytesNEON C module)."
        ),
        .trait(
            name: "HardwareCRC",
            description: "CRC-32 with ARM's CRC32 and carry-less multiply instructions (the CBytesCRC C module)."
        ),
        .trait(
            name: "HardwareCrypto",
            description: "AES, SHA-1, SHA-256, SHA-512, and GHASH with ARM's cryptography instructions (the CBytesCrypto C module)."
        ),
        .trait(
            name: "Portable",
            description: "Build the C modules as for a CPU without NEON: their portable fallbacks, to measure them here.",
            enabledTraits: ["NEONShuffle", "HardwareCRC", "HardwareCrypto"]
        ),
        .default(enabledTraits: ["NEONShuffle", "HardwareCRC", "HardwareCrypto"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.38.1"),
        .package(url: "https://github.com/swiftlang/swift-syntax", from: "603.0.0"),
        .package(url: "https://github.com/pointfreeco/swift-macro-testing", from: "0.6.5"),
    ],
    targets: [
        // NEON `tbl` wrappers Swift inlines; a portable fallback elsewhere.
        .target(name: "CBytesNEON", cSettings: portableCSettings),
        // Carry-less multiply and CRC32 instruction wrappers for `CRC32`; empty on CPUs without them.
        .target(name: "CBytesCRC", cSettings: portableCSettings),
        .target(name: "CBytesCrypto", cSettings: portableCSettings),
        .target(
            name: "Bytes",
            dependencies: [
                .target(name: "CBytesNEON", condition: .when(traits: ["NEONShuffle"])),
                .target(name: "CBytesCRC", condition: .when(traits: ["HardwareCRC"])),
            ],
            // `import Builtin`, for branch-weight and value-range hints the standard library doesn't expose.
            swiftSettings: strictSettings + portableSwiftSettings + [.enableExperimentalFeature("BuiltinModule")]
        ),
        .testTarget(
            name: "BytesTests",
            dependencies: ["Bytes", "BytesTestSupport"],
            swiftSettings: strictSettings + portableSwiftSettings
        ),
        // The asynchronous parts: `ByteBuffer.receive`, lending spans to tasks, and asynchronous pipeline stages. (The
        // parallel codecs' `async` entry points moved with BytesCompression, to its BytesCompressionAsync.)
        .target(
            name: "BytesAsync",
            dependencies: ["Bytes"],
            swiftSettings: strictSettings + portableSwiftSettings
        ),
        .testTarget(
            name: "BytesAsyncTests",
            dependencies: ["Bytes", "BytesAsync", "BytesTesting"],
            swiftSettings: strictSettings + portableSwiftSettings
        ),
        // `Data` with spans (standard library ones only), apart so `Bytes` needn't depend on Foundation.
        .target(
            name: "BytesFoundation",
            swiftSettings: strictSettings
        ),
        .testTarget(
            name: "BytesFoundationTests",
            dependencies: ["BytesFoundation"],
            swiftSettings: strictSettings
        ),
        // Base64 (RFC 4648), encoding and decoding, vectorized with `ByteLanes`. Its own module, not part of `Bytes`:
        // adding code to a module can change how the rest of it inlines (LZBITMAP's decoder, 12–15%), so the core's
        // codegen stays as it was.
        .target(
            name: "BytesBase64",
            dependencies: ["Bytes"],
            swiftSettings: strictSettings + portableSwiftSettings
        ),
        .testTarget(
            name: "BytesBase64Tests",
            dependencies: ["Bytes", "BytesBase64", "BytesTestSupport"],
            swiftSettings: strictSettings + portableSwiftSettings
        ),
        // Authenticated encryption on spans: ChaCha20-Poly1305, and TLS 1.3 record protection.
        .target(
            name: "BytesCrypto",
            dependencies: [
                "Bytes",
                // PEM's Base64.
                "BytesBase64",
                .target(name: "CBytesCrypto", condition: .when(traits: ["HardwareCrypto"])),
            ],
            swiftSettings: strictSettings + portableSwiftSettings
        ),
        .testTarget(
            name: "BytesCryptoTests",
            dependencies: ["Bytes", "BytesCrypto", "BytesTestSupport", "BytesTesting"],
            // Not strict memory safety: CryptoKit, the reference, takes `Data`.
            swiftSettings: commonSettings + portableSwiftSettings
        ),
        // (The codecs' tests and benchmarks, `CompressionBenchmarks` with BytesCrypto's rows among them, and the
        // reference libraries they compare with moved with BytesCompression to ../BytesCompression.)
        .executableTarget(
            name: "BytesBenchmarks",
            dependencies: [
                "Bytes",
                "BytesAsync",
                "BytesTestSupport",
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/BytesBenchmarks",
            swiftSettings: commonSettings + portableSwiftSettings,
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
        // Named as when Base64 was its own package, so its thresholds and baselines still match.
        .executableTarget(
            name: "Base64Benchmarks",
            dependencies: [
                "Bytes",
                "BytesBase64",
                "BytesTestSupport",
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/Base64Benchmarks",
            swiftSettings: commonSettings + portableSwiftSettings,
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
    ] + macroTargets + supportTargets
)
