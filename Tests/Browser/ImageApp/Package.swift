// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RuneBrowserImageFixture",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "rune-image-probe", targets: ["ImageProbe"]),
        .executable(name: "rune-image-page-probe", targets: ["ImagePageProbe"]),
    ],
    dependencies: [.package(name: "swift-rune", path: "../../..")],
    targets: [
        .executableTarget(name: "ImageProbe", dependencies: [.product(name: "Rune", package: "swift-rune")]),
        .executableTarget(name: "ImagePageProbe", dependencies: [
            .product(name: "Rune", package: "swift-rune"), .product(name: "RuneRef", package: "swift-rune")
        ])
    ]
)
