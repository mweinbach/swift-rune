// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RuneUIKitWindow",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [.package(name: "swift-rune", path: "../../..")],
    targets: [
        .executableTarget(name: "RuneUIKitWindow", dependencies: [
            .product(name: "Rune", package: "swift-rune")
        ], path: "Sources")
    ]
)
