// swift-tools-version: 6.4

import PackageDescription

// As in Bytes: Swift 7's upcoming features everywhere, strict memory safety in the library (every `unsafe` expression
// marked, with a comment saying why it's safe).
let commonSettings: [SwiftSetting] = [
    // `@_lifetime`: `EntryPath` is `~Escapable`, a view of the caller's bytes.
    .enableExperimentalFeature("Lifetimes"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    // A plain `nonisolated async` function runs on its caller's executor; the entry points that leave it are
    // `@concurrent`.
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
]
// `DISK_SYSCALL_COUNTING`: the `SyscallCounting` trait compiles a counter into every file system call Disk makes
// (zero cost when off, the default). The benchmarks report it as the `Disk syscalls` metric:
//
//     swift package --traits SyscallCounting --disable-sandbox benchmark     (or ./bench syscalls)
let librarySettings: [SwiftSetting] = commonSettings + [
    .strictMemorySafety(),
    .define("DISK_SYSCALL_COUNTING", .when(traits: ["SyscallCounting"])),
]

let package = Package(
    name: "Disk",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "Disk", targets: ["Disk"]),
        // Reading extracted trees in tests (items, extended attributes, ACLs, APFS compression): Disk's, NativeAEA's,
        // and NativeZip's. No Swift Testing, like Bytes' BytesTestSupport.
        .library(name: "DiskTestSupport", targets: ["DiskTestSupport"]),
    ],
    traits: [
        .trait(
            name: "SyscallCounting",
            description: "Count every file system call Disk makes, by kind (for the benchmarks' syscall metric)."
        ),
        .default(enabledTraits: []),
    ],
    dependencies: [
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.38.1"),
        .package(path: "../Bytes"),
    ],
    targets: [
        .target(
            name: "Disk",
            dependencies: [
                // Spans, `ByteLanes` (path validation), readers for the Apple Archive metadata blobs, `RawStorage`.
                .product(name: "Bytes", package: "Bytes"),
                // APFS compression's encoders (LZBITMAP, LZFSE, LZVN, zlib) and decoders (rewriting a fork that
                // didn't pay).
                .product(name: "BytesCompression", package: "Bytes"),
                // The waits: `Continuation`, `WaiterQueue`, `AsyncLimiter`, `AsyncIndexPool`, `AsyncLatch`.
                .product(name: "BytesAsync", package: "Bytes"),
            ],
            swiftSettings: librarySettings
        ),
        .target(
            name: "DiskTestSupport",
            swiftSettings: commonSettings + [.strictMemorySafety()]
        ),
        .testTarget(
            name: "DiskTests",
            dependencies: [
                "Disk",
                "DiskTestSupport",
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "BytesAsync", package: "Bytes"),
                .product(name: "BytesTestSupport", package: "Bytes"),
                .product(name: "BytesTesting", package: "Bytes"),
            ],
            swiftSettings: commonSettings
        ),
        .executableTarget(
            name: "DiskBenchmarks",
            dependencies: [
                "Disk",
                .product(name: "BytesTestSupport", package: "Bytes"),
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/DiskBenchmarks",
            swiftSettings: commonSettings,
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
    ]
)
