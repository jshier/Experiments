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

// The `Portable` trait defines `BYTES_PORTABLE` for the C headers. Swift modules compile the headers'
// `static inline` functions themselves, including ones inlined from `Bytes` into the module using it, so
// each Swift target here needs the define too (SwiftPM doesn't pass a C target's defines to its users).
let portableCSettings: [CSetting] = [.define("BYTES_PORTABLE", .when(traits: ["Portable"]))]
let portableSwiftSettings: [SwiftSetting] = [.unsafeFlags(["-Xcc", "-DBYTES_PORTABLE"], .when(traits: ["Portable"]))]

let package = Package(
    name: "Bytes",
    platforms: [.macOS(.v27), .iOS(.v27), .tvOS(.v27), .watchOS(.v27), .visionOS(.v27)],
    products: [
        .library(name: "Bytes", targets: ["Bytes"]),
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
            name: "Portable",
            description: "Build the C modules as for a CPU without NEON: their portable fallbacks, to measure them here.",
            enabledTraits: ["NEONShuffle", "HardwareCRC"]
        ),
        .default(enabledTraits: ["NEONShuffle", "HardwareCRC"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.38.1"),
    ],
    targets: [
        // NEON `tbl` wrappers Swift inlines; a portable fallback elsewhere.
        .target(name: "CBytesNEON", cSettings: portableCSettings),
        // Carry-less multiply and CRC32 instruction wrappers for `CRC32`; empty on CPUs without them.
        .target(name: "CBytesCRC", cSettings: portableCSettings),
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
            dependencies: ["Bytes"],
            swiftSettings: strictSettings + portableSwiftSettings
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
    ]
)
