// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ResumeDataBlob",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.36.0"),
    ],
    targets: [
        .target(name: "ResumeDataBlobKit"),
        .executableTarget(name: "ResumeDataBlob", dependencies: ["ResumeDataBlobKit"]),
        .executableTarget(
            name: "ResumeDataBlobBenchmarks",
            dependencies: [
                "ResumeDataBlobKit",
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/ResumeDataBlobBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "benchmark"),
            ]
        ),
    ]
)
