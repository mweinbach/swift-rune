// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RuneImeProbe",
    products: [.library(name: "RuneImeProbe", type: .dynamic, targets: ["RuneImeProbe"])],
    dependencies: [.package(name: "swift-rune", path: "../../..")],
    targets: [.target(name: "RuneImeProbe", dependencies: [.product(name: "Rune", package: "swift-rune")],
                      path: "Sources")]
)
