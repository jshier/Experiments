// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StateExplorer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "StateExplorer", path: "Sources/StateExplorer"),
    ]
)
