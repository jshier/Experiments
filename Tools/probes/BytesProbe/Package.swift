// swift-tools-version: 6.4
// Bytes' kernels on this Mac, for Tools/probe (`Tools/probe bytes`): checksum throughput by size, and the parallel
// DEFLATE encoder and decoder by lane count. Built release by Tools/probe in this directory's own .build.
import PackageDescription

let package = Package(
    name: "BytesProbe",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(path: "../../../Bytes"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    ],
    targets: [
        .executableTarget(
            name: "bytes-probe",
            dependencies: [
                .product(name: "Bytes", package: "Bytes"),
                .product(name: "BytesCompression", package: "Bytes"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/BytesProbe",
            swiftSettings: [.enableExperimentalFeature("Lifetimes")]
        ),
    ]
)
