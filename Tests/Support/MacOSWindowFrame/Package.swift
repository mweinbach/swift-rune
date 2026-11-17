// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "MacOSWindowFrame",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "SwiftRune", path: "../../..")],
    targets: [
        .executableTarget(name: "MacOSWindowFrame", dependencies: [
            .product(name: "Rune", package: "SwiftRune"),
            .product(name: "RuneMotion", package: "SwiftRune"),
        ])
    ]
)
