// swift-tools-version: 6.4

import Foundation
import PackageDescription

// MQTT packets through a local TCP socket: encoded with `BytesWriter` on one end, parsed with `BytesReader`
// on the other, over swift-platform-executors' `TCPListener`/`TCPConnection` on its PThread executors.
//
// The I/O interfaces need the `ExperimentalIO` trait and a toolchain with swiftlang/swift#91981 (the
// split continuation), and processes must run against that toolchain's Concurrency runtime. See README.md.

/// The selected toolchain's Concurrency runtime, which the executables must load instead of the OS's. Embedded
/// in each executable as `LC_DYLD_ENVIRONMENT` (`ld -dyld_env`), so it applies however they're launched: the
/// benchmark plugin, like `swift test`, doesn't pass `DYLD_LIBRARY_PATH` through to the processes it starts.
///
/// No toolchain is named here (builds come and go): the one this package needs is in `.swift-toolchain`
/// (see `../Tools/toolchains.json`), and the runtime is that of whichever toolchain the build uses:
/// `TOOLCHAIN_RUNTIME` (set by `../Tools/toolchain`), else the installed toolchain whose bundle id is
/// `TOOLCHAINS`. With neither, nothing is embedded, and the I/O fails at run time on the OS runtime.
let runtime: String? = {
    let environment = ProcessInfo.processInfo.environment
    if let runtime = environment["TOOLCHAIN_RUNTIME"] { return runtime }
    guard let id = environment["TOOLCHAINS"] else { return nil }
    for directory in ["\(NSHomeDirectory())/Library/Developer/Toolchains", "/Library/Developer/Toolchains"] {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
            let toolchain = "\(directory)/\(name)"
            guard let info = NSDictionary(contentsOfFile: "\(toolchain)/Info.plist"),
                  info["CFBundleIdentifier"] as? String == id else { continue }
            return "\(toolchain)/usr/lib/swift/macosx"
        }
    }
    return nil
}()

let useToolchainRuntime: [LinkerSetting] = runtime.map {
    [.unsafeFlags(["-Xlinker", "-dyld_env", "-Xlinker", "DYLD_LIBRARY_PATH=\($0)"])]
} ?? []

let settings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .strictMemorySafety(),
    .enableExperimentalFeature("Lifetimes"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "MQTTSocketStream",
    platforms: [.macOS(.v27)],
    dependencies: [
        .package(path: "../Bytes"),
        .package(path: "../MQTT"),
        // The revision this was built and measured with: the package changes quickly, along with the
        // toolchain it requires.
        .package(
            url: "https://github.com/swiftlang/swift-platform-executors",
            revision: "bd74d56cde5767a8bf43f803379b00790a7e9798",
            traits: ["ExperimentalIO"]
        ),
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.38.1"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    ],
    targets: [
        .target(
            name: "MQTTSocketStream",
            dependencies: [
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "MQTT", package: "MQTT"),
                .product(name: "PlatformExecutors", package: "swift-platform-executors"),
            ],
            swiftSettings: settings
        ),
        .executableTarget(
            name: "mqtt-socket-stream",
            dependencies: ["MQTTSocketStream", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            swiftSettings: settings,
            linkerSettings: useToolchainRuntime
        ),
        .testTarget(
            name: "MQTTSocketStreamTests",
            dependencies: ["MQTTSocketStream"],
            swiftSettings: settings
        ),
        .executableTarget(
            name: "MQTTSocketStreamBenchmarks",
            dependencies: ["MQTTSocketStream", .product(name: "Benchmark", package: "benchmark")],
            path: "Benchmarks/MQTTSocketStreamBenchmarks",
            swiftSettings: [.swiftLanguageMode(.v6), .enableExperimentalFeature("Lifetimes")],
            linkerSettings: useToolchainRuntime,
            plugins: [.plugin(name: "BenchmarkPlugin", package: "benchmark")]
        ),
    ]
)
