// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebSocketSendCancellation",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "WebSocketSendCancellation"),
    ]
)
