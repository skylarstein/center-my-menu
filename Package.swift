// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CenterMyMenu",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CenterMyMenuCore", targets: ["CenterMyMenuCore"])
    ],
    targets: [
        .target(name: "CenterMyMenuCore"),
        .testTarget(name: "CenterMyMenuCoreTests", dependencies: ["CenterMyMenuCore"])
    ],
    swiftLanguageModes: [.v5]
)
