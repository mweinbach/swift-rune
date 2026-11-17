// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RuneBrowserImageFixture",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "rune-image-probe", targets: ["ImageProbe"])],
    dependencies: [.package(name: "swift-rune", path: "../../..")],
    targets: [
        .executableTarget(name: "ImageProbe", dependencies: [.product(name: "Rune", package: "swift-rune")])
    ]
)
