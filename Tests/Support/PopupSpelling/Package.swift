// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "PopupSpelling",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "SwiftRune", path: "../../..")],
    targets: [
        .executableTarget(
            name: "PopupSpelling",
            dependencies: [.product(name: "Rune", package: "SwiftRune")]
        )
    ]
)
