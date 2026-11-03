// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InstantDescriptionBenchmark",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.32.0"),
    ],
    targets: [
        .executableTarget(
            name: "InstantDescription",
            dependencies: [
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/InstantDescription",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "benchmark"),
            ]
        ),
    ]
)
