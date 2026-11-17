// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "RuneBrowserSpellingFixture",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "rune-spell-probe", targets: ["SpellProbe"])],
    dependencies: [.package(name: "swift-rune", path: "../../..")],
    targets: [
        .executableTarget(name: "SpellProbe", dependencies: [.product(name: "Rune", package: "swift-rune")])
    ]
)
