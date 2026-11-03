// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebSocketPingTimeout",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "WebSocketPingTimeout"),
    ]
)
