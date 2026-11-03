// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DelayedTaskExperiment",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "DelayedTaskExperiment",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
