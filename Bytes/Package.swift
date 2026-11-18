// swift-tools-version: 6.4

import CompilerPluginSupport
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .strictMemorySafety(),
    // `@_lifetime`: `Bytes` is `~Escapable` and hands out spans that borrow the memory it reads.
    .enableExperimentalFeature("Lifetimes"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

// The `Portable` trait defines `BYTES_PORTABLE` for the C headers. Swift modules compile the headers'
// `static inline` functions themselves, including ones inlined from `Bytes` into the module using it, so
// each Swift target here needs the define too (SwiftPM doesn't pass a C target's defines to its users).
let portableCSettings: [CSetting] = [.define("BYTES_PORTABLE", .when(traits: ["Portable"]))]
let portableSwiftSettings: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-DBYTES_PORTABLE"], .when(traits: ["Portable"]))]

// `@BitFields` and `@BinaryRecord`: packed flags and fixed records that read and write themselves. (`.macro` needs
// `import CompilerPluginSupport`; without it the manifest fails as "unable to type-check this expression in
// reasonable time" rather than naming `.macro`: ~/Downloads/swift-bugs/27.)
let macroTargets: [Target] = [
    .macro(
        name: "BytesMacrosPlugin",
        dependencies: [
            .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        ],
        swiftSettings: [.swiftLanguageMode(.v6)]
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
            .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
        ],
        swiftSettings: [.swiftLanguageMode(.v6), .enableExperimentalFeature("Lifetimes")] + portableSwiftSettings
    ),
]

let package = Package(
    name: "Bytes",
    platforms: [.macOS(.v27), .iOS(.v27), .tvOS(.v27), .watchOS(.v27), .visionOS(.v27)],
    products: [
        .library(name: "Bytes", targets: ["Bytes"]),
        .library(name: "BytesCompression", targets: ["BytesCompression"]),
        .library(name: "BytesCrypto", targets: ["BytesCrypto"]),
        .library(name: "BytesAsync", targets: ["BytesAsync"]),
        .library(name: "BytesMacros", targets: ["BytesMacros"]),
        .library(name: "BytesFoundation", targets: ["BytesFoundation"]),
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
            description: "AES, SHA-1, SHA-256, and GHASH with ARM's cryptography instructions (the CBytesCrypto C module)."
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
            dependencies: ["Bytes", "BytesAsync"],
            swiftSettings: strictSettings + portableSwiftSettings
        ),
        // DEFLATE (raw, zlib, gzip) and Brotli, compressing and decompressing.
        .target(
            name: "BytesCompression",
            dependencies: ["Bytes", .target(name: "CBytesCRC", condition: .when(traits: ["HardwareCRC"]))],
            swiftSettings: strictSettings + portableSwiftSettings + [.enableExperimentalFeature("BuiltinModule")]
        ),
        // The asynchronous parts: `ByteBuffer.receive`, lending spans to tasks, the parallel codecs' `async`
        // entry points, and asynchronous pipeline stages.
        .target(
            name: "BytesAsync",
            dependencies: ["Bytes", "BytesCompression"],
            swiftSettings: strictSettings + portableSwiftSettings
        ),
        .testTarget(
            name: "BytesAsyncTests",
            dependencies: ["Bytes", "BytesCompression", "BytesAsync"],
            swiftSettings: [.swiftLanguageMode(.v6), .enableExperimentalFeature("Lifetimes")] + portableSwiftSettings
        ),
        // `Data` with spans (standard library ones only), apart so `Bytes` needn't depend on Foundation.
        .target(
            name: "BytesFoundation",
            dependencies: [],
            swiftSettings: strictSettings + portableSwiftSettings
        ),
        // Authenticated encryption on spans: ChaCha20-Poly1305, and TLS 1.3 record protection.
        .target(
            name: "BytesCrypto",
            dependencies: [
                "Bytes",
                .target(name: "CBytesCrypto", condition: .when(traits: ["HardwareCrypto"])),
            ],
            swiftSettings: strictSettings + portableSwiftSettings
        ),
        .testTarget(
            name: "BytesCryptoTests",
            dependencies: ["Bytes", "BytesCompression", "BytesCrypto"],
            // Not strict memory safety: CryptoKit, the reference, takes `Data`.
            swiftSettings: [.swiftLanguageMode(.v6), .enableExperimentalFeature("Lifetimes")] + portableSwiftSettings
        ),
        // Reference implementations, for differential tests and comparison benchmarks only. Found through
        // pkg-config: `brew install libdeflate brotli zstd xz`. (zlib and Apple's Compression come with the SDK.)
        .systemLibrary(name: "CLibDeflate", pkgConfig: "libdeflate", providers: [.brew(["libdeflate"])]),
        .systemLibrary(name: "CBrotli", pkgConfig: "libbrotlienc", providers: [.brew(["brotli"])]),
        .systemLibrary(name: "CZstd", pkgConfig: "libzstd", providers: [.brew(["zstd"])]),
        .systemLibrary(name: "CLZMA", pkgConfig: "liblzma", providers: [.brew(["xz"])]),
        .testTarget(
            name: "BytesCompressionTests",
            dependencies: ["Bytes", "BytesCompression", "BytesAsync", "CLibDeflate", "CBrotli", "CZstd", "CLZMA"],
            // Not strict memory safety: the tests call the reference libraries' C APIs.
            swiftSettings: [.swiftLanguageMode(.v6), .enableExperimentalFeature("Lifetimes")] + portableSwiftSettings
        ),
        .executableTarget(
            name: "CompressionBenchmarks",
            dependencies: [
                "BytesCompression",
                "BytesAsync",
                "BytesCrypto",
                "CLibDeflate",
                "CBrotli",
                "CZstd",
                "CLZMA",
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/CompressionBenchmarks",
            swiftSettings: [.swiftLanguageMode(.v6), .enableExperimentalFeature("Lifetimes")] + portableSwiftSettings,
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
        .executableTarget(
            name: "BytesBenchmarks",
            dependencies: [
                "Bytes",
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/BytesBenchmarks",
            swiftSettings: [.swiftLanguageMode(.v6), .enableExperimentalFeature("Lifetimes")] + portableSwiftSettings,
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
    ] + macroTargets
)
