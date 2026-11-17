// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SharedPackage",
    platforms: [.iOS(.v26)],
    products: [.library(name: "SharedPackage", targets: ["SharedPackage"])],
    targets: [.target(name: "SharedPackage")]
)
