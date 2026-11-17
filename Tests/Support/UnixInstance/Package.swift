// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "UnixInstanceRegression",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "swift-rune", path: "../../..")],
    targets: [.executableTarget(name: "InstanceProbe", dependencies: [
        .product(name: "Rune", package: "swift-rune")
    ], path: "Probe")]
)
