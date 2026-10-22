// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Bifrost", platforms: [.macOS(.v14)],
    products: [.executable(name: "BifrostHost", targets: ["BifrostApp"]), .executable(name: "bifrost", targets: ["BifrostCLI"])],
    targets: [
        .target(name: "BifrostCore"),
        .executableTarget(name: "BifrostApp", dependencies: ["BifrostCore"]),
        .executableTarget(name: "BifrostCLI", dependencies: ["BifrostCore"]),
        .testTarget(name: "BifrostCoreTests", dependencies: ["BifrostCore"])
    ]
)
