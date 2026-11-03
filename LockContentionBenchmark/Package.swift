// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "LockContentionBenchmark",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/ordo-one/benchmark", from: "1.35.0"),
    ],
    targets: [
        .executableTarget(
            name: "LockContentionBenchmark",
            dependencies: [
                .product(name: "Benchmark", package: "benchmark"),
            ],
            path: "Benchmarks/LockContentionBenchmark",
            swiftSettings: [.swiftLanguageMode(.v6)],
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "benchmark"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
