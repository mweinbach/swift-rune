// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "WindowsPopupWindowHandle",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "SwiftRune", path: "../../..")],
    targets: [
        .executableTarget(
            name: "WindowsPopupWindowHandle",
            dependencies: [.product(name: "Rune", package: "SwiftRune")]
        )
    ]
)
