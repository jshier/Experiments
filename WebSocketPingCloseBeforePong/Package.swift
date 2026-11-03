// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebSocketPingCloseBeforePong",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "WebSocketPingCloseBeforePong"),
    ]
)
