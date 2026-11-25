// swift-tools-version: 6.4

import PackageDescription

// BytesCompression: Bytes' codecs (DEFLATE, zlib, gzip, Deflate64, Brotli, Zstandard, LZMA, LZMA2, xz, bzip2, LZ4,
// LZFSE, LZVN, LZBITMAP, LZRAVEN) and their checksums, moved out of the Bytes package on 2026-11-23 with the module
// unchanged (RESULTS.md). Settings as in Bytes: Swift 7's upcoming features everywhere (`commonSettings`), strict
// memory safety in the libraries (`strictSettings`: every `unsafe` expression marked, with a comment saying why it's
// safe).
let commonSettings: [SwiftSetting] = [
    // `@_lifetime`: the codecs read and write spans.
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

// The `Portable` trait defines `BYTES_PORTABLE` for the C headers, here and (through the trait of the same name) in
// Bytes. Swift modules compile the headers' `static inline` functions themselves, including ones inlined from `Bytes`
// into the module using it, so each Swift target needs the define too (SwiftPM doesn't pass a C target's defines to
// its users, and has no Swift setting for a Clang define but `unsafeFlags`).
let portableCSettings: [CSetting] = [.define("BYTES_PORTABLE", .when(traits: ["Portable"]))]
let portableSwiftSettings: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-DBYTES_PORTABLE"], .when(traits: ["Portable"]))]

let package = Package(
    name: "BytesCompression",
    platforms: [.macOS(.v27), .iOS(.v27), .tvOS(.v27), .watchOS(.v27), .visionOS(.v27)],
    products: [
        .library(name: "BytesCompression", targets: ["BytesCompression"]),
        // The parallel codecs' `async` entry points (on a Dispatch queue, or as a task group's children).
        .library(name: "BytesCompressionAsync", targets: ["BytesCompressionAsync"]),
        // Test and benchmark support: the SDK's zlib and Compression as reference codecs (other packages' tests and
        // benchmarks use them too).
        .library(name: "BytesReferenceCodecs", targets: ["BytesReferenceCodecs"]),
    ],
    // Bytes' traits, each passed on to Bytes, so the three builds are Bytes' three (see `bench`):
    // - default: the C modules' NEON and CRC instructions (what Apple silicon gets);
    // - `--traits Portable`: the C modules' portable fallbacks (what other CPUs get), on Apple silicon;
    // - `--disable-default-traits`: no C modules, Swift only.
    traits: [
        .trait(
            name: "NEONShuffle",
            description: "Bytes' trait of the name: odd-width byte groups with NEON table lookups (CBytesNEON)."
        ),
        .trait(
            name: "HardwareCRC",
            description: "CRC-64 and bzip2's CRC with ARM's carry-less multiply (the CBytesCompression C module), and Bytes' trait of the name."
        ),
        .trait(
            name: "HardwareCrypto",
            description: "Bytes' trait of the name: BytesCrypto with ARM's cryptography instructions (the benchmarks' cipher rows)."
        ),
        .trait(
            name: "Portable",
            description: "Build the C modules as for a CPU without NEON (here and in Bytes): their portable fallbacks, to measure them here.",
            enabledTraits: ["NEONShuffle", "HardwareCRC", "HardwareCrypto"]
        ),
        .default(enabledTraits: ["NEONShuffle", "HardwareCRC", "HardwareCrypto"]),
    ],
    dependencies: [
        .package(
            path: "../Bytes",
            traits: [
                .trait(name: "NEONShuffle", condition: .when(traits: ["NEONShuffle"])),
                .trait(name: "HardwareCRC", condition: .when(traits: ["HardwareCRC"])),
                .trait(name: "HardwareCrypto", condition: .when(traits: ["HardwareCrypto"])),
                .trait(name: "Portable", condition: .when(traits: ["Portable"])),
            ]
        ),
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.38.1"),
    ],
    targets: [
        // Carry-less multiply wrappers for CRC-64's and bzip2's folding (copied from Bytes' CBytesCRC, which keeps
        // its own for CRC-32 and Adler-32); empty on CPUs without them.
        .target(name: "CBytesCompression", cSettings: portableCSettings),
        // DEFLATE (raw, zlib, gzip) and Brotli, compressing and decompressing; the other formats decoding (and
        // Zstandard, LZFSE, LZVN, LZBITMAP encoding).
        .target(
            name: "BytesCompression",
            dependencies: [
                .product(name: "Bytes", package: "Bytes"),
                .target(name: "CBytesCompression", condition: .when(traits: ["HardwareCRC"])),
            ],
            // `import Builtin`, for value-range hints and vector reductions the standard library doesn't expose.
            swiftSettings: strictSettings + portableSwiftSettings + [.enableExperimentalFeature("BuiltinModule")]
        ),
        // The parallel codecs' `async` entry points: their own module (was in BytesAsync), so BytesCompression's
        // contents, and so its inlining, stay as they were.
        .target(
            name: "BytesCompressionAsync",
            dependencies: [
                "BytesCompression",
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "BytesAsync", package: "Bytes"),
            ],
            swiftSettings: strictSettings + portableSwiftSettings
        ),
        .target(
            name: "BytesReferenceCodecs",
            // Not strict memory safety: it's C calls through and through.
            swiftSettings: commonSettings
        ),
        // Reference implementations, for differential tests and comparison benchmarks only. Found through
        // pkg-config: `brew install libdeflate brotli zstd xz`. (zlib and Apple's Compression come with the SDK.)
        .systemLibrary(name: "CLibDeflate", pkgConfig: "libdeflate", providers: [.brew(["libdeflate"])]),
        .systemLibrary(name: "CBrotli", pkgConfig: "libbrotlienc", providers: [.brew(["brotli"])]),
        .systemLibrary(name: "CZstd", pkgConfig: "libzstd", providers: [.brew(["zstd"])]),
        .systemLibrary(name: "CLZMA", pkgConfig: "liblzma", providers: [.brew(["xz"])]),
        // libbzip2, from the SDK.
        .systemLibrary(name: "CBZip2"),
        // (The lzfse and libzbitmap C references that BytesCompression's LZFSE, LZVN, and LZBITMAP coders were
        // checked against are no longer built: `Tools/test-data fetch c-references` has their source, and
        // Benchmarks/RESULTS-lz4-lzfse.md and RESULTS-lzbitmap.md say how to add them back as targets.)
        .testTarget(
            name: "BytesCompressionTests",
            dependencies: [
                "BytesCompression", "BytesCompressionAsync", "CLibDeflate", "CBrotli", "CZstd", "CLZMA", "CBZip2",
                "BytesReferenceCodecs",
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "BytesAsync", package: "Bytes"),
                // Pipelines of codecs and TLS records (PipelineTests).
                .product(name: "BytesCrypto", package: "Bytes"),
                .product(name: "BytesTestSupport", package: "Bytes"),
                .product(name: "BytesTesting", package: "Bytes"),
            ],
            // Not strict memory safety: the tests call the reference libraries' C APIs.
            swiftSettings: commonSettings + portableSwiftSettings
        ),
        // Named as when it was in Bytes, so its thresholds and baselines still match. (It has BytesCrypto's rows too:
        // ciphers, hashes, ECC, RSA, TLS records, and pipelines of codecs and records.)
        .executableTarget(
            name: "CompressionBenchmarks",
            dependencies: [
                "BytesCompression",
                "BytesCompressionAsync",
                "CLibDeflate",
                "CBrotli",
                "CZstd",
                "CLZMA",
                "CBZip2",
                "BytesReferenceCodecs",
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "BytesAsync", package: "Bytes"),
                .product(name: "BytesCrypto", package: "Bytes"),
                .product(name: "BytesTestSupport", package: "Bytes"),
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/CompressionBenchmarks",
            swiftSettings: commonSettings + portableSwiftSettings,
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
    ]
)
