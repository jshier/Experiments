// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "SuperscriptBenchmark",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.35.0"),
    ],
    targets: [
        .executableTarget(
            name: "SuperscriptBenchmark",
            dependencies: [
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/SuperscriptBenchmark",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "benchmark"),
            ]
        ),
    ]
)
