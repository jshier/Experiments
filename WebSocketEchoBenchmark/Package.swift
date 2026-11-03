// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WebSocketEchoBenchmark",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../Alamofire"),
        .package(url: "https://github.com/ordo-one/package-benchmark", from: "1.32.0"),
    ],
    targets: [
        .executableTarget(
            name: "WebSocketEchoBenchmark",
            dependencies: [
                .product(name: "Alamofire", package: "Alamofire"),
            ]
        ),
        .executableTarget(
            name: "WebSocketEcho",
            dependencies: [
                .product(name: "Benchmark", package: "package-benchmark"),
                .product(name: "Alamofire", package: "Alamofire"),
            ],
            path: "Benchmarks/WebSocketEcho",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "package-benchmark"),
            ]
        ),
    ]
)
