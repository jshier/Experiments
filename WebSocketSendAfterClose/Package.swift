// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WebSocketSendAfterClose",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "WebSocketSendAfterClose"),
    ]
)
